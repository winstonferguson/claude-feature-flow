#!/usr/bin/env ruby
# frozen_string_literal: true

# Safety checks for the feature flow: issue -> draft PR -> approve draft ->
# interaction tests -> ready. The flow itself lives in the feature-flow skill;
# this script only refuses what agents must never do:
#
# 1. Writes to protected paths (never_writable), by any file tool.
# 2. Commits and pushes on, or to, a protected branch.
# 3. Denied commands.
# 4. Writes under needs_approve_spec (migrations, ADRs) until the maintainer
#    types "approve spec".
# 5. GitHub writes other than: editing or commenting on the flow's own issue,
#    opening a draft PR, updating the PR, and replying on review threads.
#    Merging and approving are always refused.
# 6. Marking the PR ready, or opening a non-draft one, until a ready
#    "full diff" verdict covers the pushed commit.
#
# Hook events (see .claude/settings.json):
# - SessionStart and UserPromptSubmit: status line, and the maintainer's typed
#   commands. Only a person's message triggers UserPromptSubmit, so agents
#   can't approve.
# - PostToolUse on the Agent tool: record the reviewer's verdict for the files
#   as they are. A reviewer launched in the background is recorded as pending
#   and read from its output file at the start of a later hook call.
# - PreToolUse: the checks above.
# - Stop: ping Slack that Claude is waiting, if SLACK_WEBHOOK_URL is set.
#
# It only runs in cloud sessions (CLAUDE_CODE_REMOTE=true). State lives in a
# ledger per branch, .claude/flow/ledgers/<branch>.json, ignored by git.
#
# Tests run arbitrary code, so the session isn't a security boundary. These
# hooks keep agents on the flow. What protects main is branch protection and
# the maintainer merging.

exit 0 unless ENV["CLAUDE_CODE_REMOTE"] == "true"

require "json"
require "time"
require "open3"
require "tmpdir"
require "digest"
require "fileutils"
require "net/http"

Encoding.default_external = Encoding::UTF_8
$stdin.set_encoding(Encoding::UTF_8)

ROOT = ENV.fetch("CLAUDE_PROJECT_DIR") { Dir.pwd }
LEDGER_DIR = ".claude/flow/ledgers"
CONFIG = JSON.parse(File.read(File.join(ROOT, ".claude", "flow", "config.json")))

BUILDER = CONFIG.fetch("builder_agent")
REVIEWER = CONFIG.fetch("reviewer_agent")
PROTECTED = CONFIG.fetch("protected_branches")
NEVER_WRITABLE = CONFIG.fetch("never_writable")
NEEDS_SPEC = CONFIG.fetch("needs_approve_spec", [])
DENIED = CONFIG.fetch("denied_commands", [])

FILE_TOOLS = %w[Edit Write MultiEdit NotebookEdit].freeze

module Git
  module_function

  def run(*args, env: {})
    out, status = Open3.capture2e(env, "git", "-C", ROOT, *args)
    [out.strip, status.success?]
  end

  def branch = run("branch", "--show-current").first

  def clean? = run("status", "--porcelain", "--", ".", ":(exclude)#{LEDGER_DIR}").first.empty?

  def branch_exists?(name) = run("rev-parse", "--verify", "--quiet", "refs/heads/#{name}").last

  # The commit a plain "git push" last sent, as git last fetched or pushed it, or nil.
  def pushed_commit
    out, ok = run("rev-parse", "--verify", "--quiet", "@{push}")
    ok ? out : nil
  end

  # A fingerprint of the working tree's content, staged or not, ignoring the
  # ledgers. Same content gives the same value, whatever has been committed.
  def tree
    with_index("HEAD") { |env| run("add", "-A", "--", ".", ":(exclude)#{LEDGER_DIR}", env: env) }
  end

  # The same fingerprint for a commit.
  def commit_tree(commit) = with_index(commit) { nil }

  def with_index(tree)
    Dir.mktmpdir do |dir|
      env = { "GIT_INDEX_FILE" => File.join(dir, "index") }
      run("read-tree", tree, env: env)
      run("rm", "-r", "--cached", "--quiet", "--ignore-unmatch", "--", LEDGER_DIR, env: env)
      yield env
      run("write-tree", env: env).first
    end
  end
end

class Ledger
  attr_reader :data, :path

  def self.path_for(branch) = File.join(ROOT, LEDGER_DIR, "#{branch.gsub(/[^A-Za-z0-9_.-]/, '--')}.json")

  # Branch names can share a file ("feature/x" and "feature--x"), and a new
  # branch can carry another branch's ledger: either way it isn't this flow.
  def self.load(branch)
    path = path_for(branch)
    return nil unless File.exist?(path)

    data = JSON.parse(File.read(path))
    data["branch"] == branch ? new(path, data) : nil
  end

  def self.start(mode, slug, branch, issue)
    new(path_for(branch), {
      "feature" => slug, "mode" => mode, "branch" => branch, "issue" => issue, "active" => true,
      "approvals" => [], "verdicts" => [], "pending" => nil, "log" => []
    })
  end

  def initialize(path, data)
    @path = path
    @data = data
  end

  def active? = data["active"] == true
  def issue = data["issue"]
  def approved?(name) = data["approvals"].any? { _1["name"] == name }

  def last_full_diff = data["verdicts"].reverse.find { _1["checked"] == "full diff" }

  def log(event, detail, agent = "")
    data["log"] << { "at" => now, "event" => event, "detail" => detail, "agent" => agent }
  end

  def save
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "#{JSON.pretty_generate(data)}\n")
  end

  def now = Time.now.utc.iso8601
end

module Out
  module_function

  def context(event, text)
    puts JSON.generate({ hookSpecificOutput: { hookEventName: event, additionalContext: text } })
    exit 0
  end

  def deny(reason)
    puts JSON.generate({ hookSpecificOutput: {
      hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: reason
    } })
    exit 0
  end

  def allow
    exit 0
  end
end

# What to do about a block, added to every refusal and status line.
BLOCKED_NOTE = "If a block names a way forward, take it and note the block in the PR notes. " \
               "Otherwise stop and tell the maintainer. Never work around a block."

# ---------------------------------------------------------------------------
# Status, and the maintainer's typed commands (the first line of their message).

def status_text(ledger, branch)
  if ledger.nil?
    return "Flow: no flow on branch '#{branch}'. Files can't be changed until the maintainer types " \
           "'start feature #<issue>' or 'start fix <name>'. Don't try to start one yourself."
  end
  return "Flow: the flow for '#{ledger.data['feature']}' is stopped. No changes are allowed on this branch." unless ledger.active?

  issue = ledger.issue ? " for issue ##{ledger.issue}" : ""
  v = ledger.data["verdicts"].last
  ["Flow: #{ledger.data['mode']} '#{ledger.data['feature']}'#{issue}, branch #{ledger.data['branch']}.",
   "approve spec: #{ledger.approved?('spec') ? 'recorded' : "not recorded (needed only to write #{NEEDS_SPEC.join(', ')})"}.",
   "approve draft: #{ledger.approved?('draft') ? 'recorded' : 'not yet'}.",
   "Last review: #{v ? "#{v['verdict']} (checked #{v['checked'] || 'unknown'})" : 'none yet'}.",
   BLOCKED_NOTE].join(" ")
end

def reply(text) = Out.context("UserPromptSubmit", text)

def handle_prompt(input)
  branch = Git.branch
  ledger = Ledger.load(branch)
  first_line = input["prompt"].to_s.strip.lines.first.to_s.strip.downcase

  case first_line
  when /\Astart (feature|fix)(?:\s+(.*?))?\s*\z/
    mode, rest = Regexp.last_match(1), Regexp.last_match(2).to_s
    issue = rest[/(?:\A|\s)#(\d+)\z/, 1]&.to_i
    slug = slugify(rest.sub(/#\d+\z/, "")).then { _1.empty? && issue ? "issue-#{issue}" : _1 }
    reply("Flow not started. Type 'start feature #<issue>' or 'start fix <name>'.") if slug.empty?
    start_flow(mode, slug, issue, branch)
  when /\Aapprove (spec|draft)\s*\z/ then approve(ledger, Regexp.last_match(1))
  when /\Astop flow\b/ then stop_flow(ledger)
  else reply(status_text(ledger, branch))
  end
end

# Any wording the maintainer types, as a branch-safe name: "Show project’s #1" -> "show-projects".
def slugify(text) = text.downcase.delete("'’").gsub(/[^a-z0-9]+/, "-").delete_prefix("-").delete_suffix("-")

# On main, the flow gets a new branch. On any other branch (such as the one a
# cloud session starts on), the flow runs on that branch.
def start_flow(mode, slug, issue, branch)
  reply("Flow not started: a feature needs its issue, as 'start feature #<issue>'.") if mode == "feature" && issue.nil?
  reply("Flow not started: the working tree has uncommitted changes.") unless Git.clean?
  reply("Flow not started: this branch already has a flow. Type 'stop flow' first.") if Ledger.load(branch)&.active?

  new_branch = branch
  if PROTECTED.include?(branch) || branch.empty?
    new_branch = "#{mode}/#{slug}"
    reply("Flow not started: branch '#{new_branch}' already exists.") if Git.branch_exists?(new_branch)
    _, ok = Git.run("switch", "-c", new_branch)
    reply("Flow not started: couldn't create branch '#{new_branch}'.") unless ok
  end
  ledger = Ledger.start(mode, slug, new_branch, issue)
  ledger.log("start", "started by the maintainer")
  ledger.save
  reply("Flow started by the maintainer. #{status_text(ledger, new_branch)}")
end

def approve(ledger, name)
  reply("Nothing to approve: no active flow on this branch.") unless ledger&.active?
  reply("'approve #{name}' is already recorded.") if ledger.approved?(name)

  ledger.data["approvals"] << { "name" => name, "at" => ledger.now }
  ledger.log("approve", "#{name} approved by the maintainer")
  ledger.save
  reply("Approved by the maintainer. #{status_text(ledger, ledger.data['branch'])}")
end

def stop_flow(ledger)
  reply("No active flow on this branch.") unless ledger&.active?
  ledger.data["active"] = false
  ledger.log("stop", "stopped by the maintainer")
  ledger.save
  reply("Flow stopped by the maintainer. No changes are allowed on this branch now.")
end

# ---------------------------------------------------------------------------
# The reviewer's verdicts, read when the Agent tool that launched it returns.

def handle_post_tool_use(input)
  Out.allow unless input.dig("tool_input", "subagent_type") == REVIEWER
  ledger = Ledger.load(Git.branch)
  Out.allow unless ledger&.active?

  response = input["tool_response"]
  if response.is_a?(Hash) && response["isAsync"] == true && response["status"] == "async_launched"
    ledger.log("superseded", "pending review #{ledger.data['pending']['agent_id']} dropped", REVIEWER) if ledger.data["pending"]
    ledger.data["pending"] = { "agent_id" => response["agentId"], "output_file" => response["outputFile"],
                               "tree" => Git.tree, "at" => ledger.now }
    ledger.save
    Out.allow
  end

  if ledger.data["pending"]
    ledger.log("superseded", "pending review #{ledger.data['pending']['agent_id']} dropped", REVIEWER)
    ledger.data["pending"] = nil
  end
  source, message = reply_text(response)
  record_verdict(ledger, message, source, Git.tree, response)
  ledger.save
  Out.allow
end

def record_verdict(ledger, message, source, tree, response)
  verdict = message.to_s[VERDICT_LINE, 1]&.downcase
  entry = { "verdict" => verdict || "unreadable", "checked" => message.to_s[CHECKED_LINE, 1]&.downcase,
            "tree" => tree, "at" => ledger.now }
  verdict ? entry["source"] = source : entry["received"] = received(response)
  ledger.data["verdicts"] << entry
end

# Reads the report of a reviewer launched in the background. With no report
# yet, it stays pending.
def resolve_pending
  ledger = Ledger.load(Git.branch)
  review = ledger&.data&.dig("pending")
  message = review && handback(review["output_file"])
  return unless message

  record_verdict(ledger, message, "outputFile", review["tree"], message)
  ledger.data["pending"] = nil
  ledger.save
end

# The agent's report in its JSONL output file: the message of its last
# SubagentHandback call, or nil while it hasn't made one.
def handback(path)
  return nil unless path.is_a?(String) && File.exist?(path)

  calls = File.foreach(path).flat_map do |line|
    entry = JSON.parse(line) rescue nil
    content = entry.is_a?(Hash) && entry["message"].is_a?(Hash) ? entry["message"]["content"] : nil
    content.is_a?(Array) ? content : []
  end
  call = calls.reverse.find { _1.is_a?(Hash) && _1["type"] == "tool_use" && _1["name"] == "SubagentHandback" }
  call&.dig("input", "message")
end

# The whole line must be one value, so a copied template line doesn't count.
VERDICT_LINE = /^[\s*_#>-]*verdict[*_]*\s*:[*_ \t]*(ready|fix first|needs the maintainer)[*_. \t]*$/i
CHECKED_LINE = /^[\s*_#>-]*checked[*_]*\s*:[*_ \t]*(slice|interaction|full diff)[*_. \t]*$/i

# Where the Agent tool's response may hold the reply, in the order searched.
# In cloud sessions "content" can say only that the report was delivered as a
# message, with the report itself under one of the others.
REPLY_KEYS = %w[content handbackReport handback].freeze

# The key and text of the agent's reply: the first that holds verdict and
# checked lines, then the first with a verdict line, otherwise the longest.
def reply_text(response)
  parts = response.is_a?(Hash) ? REPLY_KEYS.map { [_1, text_in(response[_1])] } : [["content", text_in(response)]]
  parts.find { _2.match?(VERDICT_LINE) && _2.match?(CHECKED_LINE) } || parts.find { _2.match?(VERDICT_LINE) } ||
    parts.max_by { _2.length }
end

def text_in(value)
  case value
  when String then value
  when Hash then value.key?("text") ? text_in(value["text"]) : value.values.map { text_in(_1) }.join("\n")
  when Array then value.map { text_in(_1) }.join("\n")
  else ""
  end
end

# What the hook was given when the verdict couldn't be read. It goes to a file
# outside the repo, as the reply can hold secrets; the ledger gets the path.
def received(response)
  keys = case response
         when Hash then response.keys
         when Array then response.grep(Hash).flat_map(&:keys).uniq
         else []
         end
  lines = ["class: #{response.class.name}", "keys: #{keys.empty? ? 'none' : keys.join(', ')}",
           "start: #{response.to_s[0, 300].inspect}"]
  lines += REPLY_KEYS.map { "#{_1}: #{response.key?(_1) ? response[_1].to_s[0, 300].inspect : 'missing'}" } if response.is_a?(Hash)
  path = "/tmp/flow-gate/unreadable-#{Time.now.utc.strftime('%Y%m%dT%H%M%S%LZ')}.txt"
  FileUtils.mkdir_p(File.dirname(path))
  File.write(path, lines.join("\n") + "\n")
  "see #{path}"
end

# ---------------------------------------------------------------------------
# Checks before each tool call.

def handle_pre_tool_use(input)
  tool = input["tool_name"].to_s
  branch = Git.branch
  ledger = Ledger.load(branch)
  gate = Gate.new(ledger, branch, input["agent_type"].to_s)
  tool_input = input["tool_input"] || {}

  reason =
    if tool.downcase.include?("merge") then MERGE
    elsif tool.downcase.include?("github") then gate.github(tool.split("__").last, tool_input)
    elsif FILE_TOOLS.include?(tool) then gate.file_change(tool_input["file_path"] || tool_input["notebook_path"])
    elsif tool == "Bash" then gate.bash(tool_input["command"].to_s)
    end

  Out.allow unless reason
  if ledger
    ledger.log("blocked", "#{tool}: #{reason}", input["agent_type"].to_s)
    ledger.save
  end
  Out.deny("#{reason} #{BLOCKED_NOTE}")
end

MERGE = "Merging and approving are the maintainer's steps; agents never do them."

# GitHub tools that only read, such as get_me, list_commits or pull_request_read.
GITHUB_READ = /\A(get|list|search)(_|\z)|_read\z/i

GITHUB_WRITES = "Agents may edit and comment on the flow's own issue, create issues labelled ai-agent, " \
                "open a draft PR, update the PR and reply on its review threads; nothing else on GitHub."

NEEDS_AI_LABEL = "A new issue needs the ai-agent label. #{GITHUB_WRITES}"

READY = "Marking the PR ready needs a ready 'full diff' review that covers the pushed commit: " \
        "run the reviewer with the Agent tool on the pushed files, then try again."

class Gate
  def initialize(ledger, branch, agent)
    @ledger = ledger
    @branch = branch
    @agent = agent
  end

  def main_session? = @agent.empty?

  # Returns a reason to refuse, or nil.
  def file_change(path)
    return "The reviewer never changes files." if @agent == REVIEWER
    return "Can't tell which file this changes." if path.to_s.empty?

    full = File.expand_path(path, ROOT)
    return "Only files inside the repository can be changed." unless full.start_with?("#{ROOT}/")

    rel = full.delete_prefix("#{ROOT}/")
    return "No changes on #{@branch}. The maintainer starts a flow by typing 'start feature #<issue>'." if PROTECTED.include?(@branch)
    return "No active flow on this branch, so no changes are allowed." unless @ledger&.active?
    return "#{rel} can't be changed by agents." if matches?(rel, NEVER_WRITABLE)
    if matches?(rel, NEEDS_SPEC) && !@ledger.approved?("spec")
      return "#{rel} changes stored data or an ADR: run the architecture check against the ADRs in " \
             "docs/architecture/, put the proposed shape in the issue, and wait for the maintainer " \
             "to type 'approve spec'."
    end

    nil
  end

  def github(name, input)
    return nil if name.match?(GITHUB_READ)
    return MERGE if name.match?(/merge|review/i) && name != "add_reply_to_pull_request_comment"
    return "Only the main session writes to GitHub. #{GITHUB_WRITES}" unless main_session?
    return "No active flow on this branch. #{GITHUB_WRITES}" unless @ledger&.active?

    case name
    when "create_pull_request" then input["draft"] == true ? nil : ready_pr
    when "update_pull_request" then input["draft"] == false ? ready_pr : nil
    when "add_reply_to_pull_request_comment" then nil
    when "issue_write"
      if input["method"] == "create"
        Array(input["labels"]).include?("ai-agent") ? nil : NEEDS_AI_LABEL
      else
        own_issue?(input["issue_number"]) ? nil : "Only issue ##{@ledger.issue} can be edited. #{GITHUB_WRITES}"
      end
    when "add_issue_comment"
      own_issue?(input["issue_number"]) ? nil : "Only issue ##{@ledger.issue} can be commented on. #{GITHUB_WRITES}"
    else GITHUB_WRITES
    end
  end

  # Shell commands are checked only for commits and pushes, gh writes and the
  # commands config denies. Heredocs with a quoted delimiter and quoted
  # strings are literal text, so a message that mentions a command isn't one.
  # A quoted single word, like --label "ai-agent", is unquoted.
  def bash(command)
    text = command.gsub(/<<-?\s*(['"])(\w+)\1.*?^\s*\2\s*$/m, "<<HEREDOC")
    text = text.gsub(/(['"])([\w.,\/-]+)\1/, '\2')
    text = text.gsub(/'[^']*'/, "''").gsub(/"(?:\\.|[^"\\])*"/, '""')
    text.split(/&&|\|\||[;|\n&]/).map(&:split).map { unwrap(_1) }.reject(&:empty?).each do |words|
      reason = segment(words)
      return reason if reason
    end
    nil
  end

  private

  def own_issue?(number) = !@ledger.issue.nil? && number.to_i == @ledger.issue

  def ready_pr
    return "The reviewer hasn't finished; wait for its report." if @ledger.data["pending"]

    review = @ledger.last_full_diff
    pushed = Git.pushed_commit
    return nil if review && review["verdict"] == "ready" && pushed && Git.commit_tree(pushed) == review["tree"]

    READY
  end

  def matches?(rel, patterns)
    flags = File::FNM_PATHNAME | File::FNM_DOTMATCH | File::FNM_EXTGLOB
    patterns.any? { File.fnmatch?(_1, rel, flags) }
  end

  # Drops leading VAR=value, env, time, nice, command and bundle exec.
  def unwrap(words)
    words = words.drop(1) while words.first&.match?(/\A\w+=/) || %w[env time nice command nohup].include?(words.first)
    words = words.drop(2) if words[0] == "bundle" && words[1] == "exec"
    words
  end

  def segment(words)
    cmd = File.basename(words.first)
    return "#{cmd} isn't allowed for agents." if DENIED.include?(cmd)
    return git(words.drop(1)) if cmd == "git"
    return gh(words.drop(1)) if cmd == "gh"

    nil
  end

  # Skips a CLI's own options before its subcommand, such as git -C dir.
  def skip_options(args, with_value)
    args = args.dup
    while args.first&.start_with?("-")
      flag = args.shift
      args.shift if with_value.include?(flag)
    end
    args
  end

  def git(args)
    args = skip_options(args, %w[-C -c --config-env])
    case args.first
    when "commit"
      return "Only the main session commits, after the reviewer returns ready." unless main_session?
      return "No commits on #{@branch}." if PROTECTED.include?(@branch)
      return "No active flow on this branch, so nothing can be committed." unless @ledger&.active?
    when "push"
      targets = args.drop(1).reject { _1.start_with?("-") }.drop(1).map { _1.split(":").last.delete_prefix("+").delete_prefix("refs/heads/") }
      return "No pushes to #{PROTECTED.join(' or ')}." if PROTECTED.include?(@branch) || targets.any? { PROTECTED.include?(_1) }
    end
    nil
  end

  def gh(args)
    group, action, *rest = skip_options(args, %w[-R --repo])
    return MERGE if group == "pr" && %w[merge review].include?(action)
    return nil unless %w[pr issue].include?(group)
    return nil if %w[view list status checks diff checkout].include?(action)
    return "Only the main session writes to GitHub. #{GITHUB_WRITES}" unless main_session?
    return "No active flow on this branch. #{GITHUB_WRITES}" unless @ledger&.active?

    if group == "pr"
      return ready_pr if action == "ready" || (action == "create" && !rest.intersect?(%w[--draft -d]))
      return nil if %w[create edit comment].include?(action)
    elsif action == "create"
      return ai_agent_label?(rest) ? nil : NEEDS_AI_LABEL
    elsif %w[edit comment].include?(action) && own_issue?(rest.find { _1.match?(/\A#?\d+\z/) }.to_s.delete_prefix("#"))
      return nil
    end
    GITHUB_WRITES
  end

  # True when a --label or -l value, comma-separated or not, names ai-agent.
  def ai_agent_label?(args)
    args.each_cons(2).any? { |flag, value| %w[--label -l].include?(flag) && value.split(",").include?("ai-agent") }
  end
end

# ---------------------------------------------------------------------------
# The Slack ping when Claude stops. Cloud sessions fire Stop twice a few
# seconds apart, so a ping within DEBOUNCE seconds of the last is skipped.

DEBOUNCE = 90
SLACK_MARKER = "/tmp/flow-gate/slack-#{Digest::SHA1.hexdigest(ROOT)}"

def notify_slack
  url = ENV["SLACK_WEBHOOK_URL"].to_s
  return if url.empty?
  return if File.exist?(SLACK_MARKER) && Time.now - File.mtime(SLACK_MARKER) < DEBOUNCE

  uri = URI(url)
  response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                                 open_timeout: 5, read_timeout: 5, write_timeout: 5) do |http|
    http.post(uri.request_uri, JSON.generate({ text: waiting_text(Git.branch) }), "Content-Type" => "application/json")
  end
  return unless response.is_a?(Net::HTTPSuccess)

  FileUtils.mkdir_p(File.dirname(SLACK_MARKER))
  FileUtils.touch(SLACK_MARKER)
rescue StandardError
  nil
end

# What Claude is waiting on: "<feature> #<issue> · <phase>: needs a reply".
def waiting_text(branch)
  ledger = Ledger.load(branch)
  return "#{branch}: needs a reply" unless ledger&.active?

  phase = ledger.approved?("draft") ? "interaction" : "draft"
  issue = ledger.issue ? " ##{ledger.issue}" : ""
  "#{ledger.data['feature']}#{issue} · #{phase}: needs a reply"
end

# ---------------------------------------------------------------------------

input = {}
begin
  input = JSON.parse($stdin.read)
  if input["hook_event_name"] == "Stop"
    notify_slack
    exit 0
  end

  # One hook at a time per repo, so parallel tool calls can't lose ledger writes.
  lock_path = File.join(Dir.tmpdir, "flow-gate-#{Digest::SHA1.hexdigest(ROOT)}.lock")
  File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
    lock.flock(File::LOCK_EX)
    resolve_pending
    case input["hook_event_name"]
    when "SessionStart" then Out.context("SessionStart", status_text(Ledger.load(Git.branch), Git.branch))
    when "UserPromptSubmit" then handle_prompt(input)
    when "PostToolUse" then handle_post_tool_use(input)
    when "PreToolUse" then handle_pre_tool_use(input)
    end
  end
  Out.allow
rescue StandardError => e
  # Fail closed: a broken gate blocks rather than lets everything through.
  Out.deny("The flow hook failed (#{e.class}: #{e.message}). Tell the maintainer.") if input["hook_event_name"] == "PreToolUse"
  warn "flow hook error: #{e.class}: #{e.message}"
  exit 1
end
