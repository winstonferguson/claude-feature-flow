# frozen_string_literal: true

# Tests for flow_gate.rb. Each test builds a throwaway git repo with this
# repo's .claude/ hooks and config, then feeds the script hook events the way
# Claude Code would. Run: ruby .claude/hooks/flow_gate_test.rb

require "minitest/autorun"
require "json"
require "open3"
require "tmpdir"
require "fileutils"
require "socket"
require "digest"

class FlowGateTest < Minitest::Test
  SOURCE = File.expand_path("..", __dir__) # this repo's .claude/
  SCRIPT = File.join(SOURCE, "hooks", "flow_gate.rb")

  def setup
    @remote = "true"
    @repo = Dir.mktmpdir("flow-repo")
    FileUtils.mkdir_p(File.join(@repo, ".claude", "flow"))
    FileUtils.cp(File.join(SOURCE, "flow", "config.json"), File.join(@repo, ".claude", "flow"))
    write("app/models/invoice.rb", "class Invoice; end\n")
    write("test/models/invoice_test.rb", "# test\n")
    FileUtils.cp(File.join(SOURCE, "..", ".gitignore"), @repo)
    git("init", "--quiet", "--initial-branch=main")
    git("config", "user.email", "test@example.com")
    git("config", "user.name", "Test")
    git("add", "-A")
    git("commit", "--quiet", "-m", "Initial")
  end

  def teardown = FileUtils.rm_rf([@repo, @origin, slack_marker].compact)

  # --- helpers -------------------------------------------------------------

  def git(*args) = Open3.capture2e("git", "-C", @repo, *args).first.strip

  def write(path, content)
    full = File.join(@repo, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, content)
  end

  def hook(event, fields = {}, env = {})
    input = { "hook_event_name" => event, "session_id" => "s", "cwd" => @repo }.merge(fields)
    env = { "CLAUDE_PROJECT_DIR" => @repo, "CLAUDE_CODE_REMOTE" => @remote }.merge(env)
    out, err, status = Open3.capture3(env, "ruby", SCRIPT, stdin_data: JSON.generate(input))
    flunk("hook crashed: #{err}") unless status.success?
    out.strip.empty? ? {} : JSON.parse(out)
  end

  def say(text) = hook("UserPromptSubmit", "prompt" => text).dig("hookSpecificOutput", "additionalContext").to_s

  def pre(tool, tool_input, agent: nil)
    fields = { "tool_name" => tool, "tool_input" => tool_input }
    fields.merge!("agent_id" => "a1", "agent_type" => agent) if agent
    output = hook("PreToolUse", fields)
    output.dig("hookSpecificOutput", "permissionDecision") == "deny" ? output.dig("hookSpecificOutput", "permissionDecisionReason") : :allowed
  end

  def edit(path, agent: nil) = pre("Edit", { "file_path" => File.join(@repo, path), "old_string" => "a", "new_string" => "b" }, agent: agent)
  def bash(command, agent: nil) = pre("Bash", { "command" => command }, agent: agent)
  def github(tool, tool_input = {}, agent: nil) = pre("mcp__github__#{tool}", tool_input, agent: agent)

  # The coordinator's Agent call returning with the agent's reply.
  def returns(agent, response)
    hook("PostToolUse", "tool_name" => "Agent", "tool_input" => { "subagent_type" => agent, "prompt" => "go" },
                        "tool_response" => response)
  end

  def review(verdict, checked)
    returns("reviewer", [{ "type" => "text", "text" => "Verdict: #{verdict}" },
                         { "type" => "text", "text" => "Checked: #{checked}\n\nFindings:\n1. none" }])
  end

  # The coordinator launching the reviewer in the background; its transcript
  # goes to an output file, as the platform writes it.
  def launch_reviewer(id = "a1")
    @output = File.join(@repo, ".git", "reviewer-#{id}.jsonl")
    transcript([{ "type" => "user", "message" => { "role" => "user", "content" => "Review the slice." } }])
    returns("reviewer", { "isAsync" => true, "status" => "async_launched", "agentId" => id,
                          "description" => "Review", "prompt" => "go", "outputFile" => @output })
  end

  def transcript(entries) = File.write(@output, entries.map { JSON.generate(_1) }.join("\n") + "\n")

  def tool_use(id, name, input) = { "type" => "assistant", "message" => { "role" => "assistant", "content" => [
    { "type" => "text", "text" => "Working." }, { "type" => "tool_use", "id" => id, "name" => name, "input" => input }
  ] } }

  def tool_result(id, text) = { "type" => "user", "message" => { "role" => "user", "content" => [
    { "type" => "tool_result", "tool_use_id" => id, "content" => text }
  ] } }

  # The reviewer still reading, then, with a report, handing it back.
  def reviewer_runs(report = nil)
    entries = [{ "type" => "user", "message" => { "role" => "user", "content" => "Review the slice." } },
               tool_use("t1", "Read", { "file_path" => "app/models/invoice.rb" }), tool_result("t1", "class Invoice")]
    entries += [tool_use("t2", "SubagentHandback", { "message" => report }), tool_result("t2", "Report delivered to your caller")] if report
    transcript(entries)
  end

  def ledger = JSON.parse(File.read(File.join(@repo, ".claude/flow/ledgers", "#{git('branch', '--show-current').gsub('/', '--')}.json")))

  def start! = say("start feature duplicate-invoice #92")

  def commit!(message = "work")
    git("add", "-A")
    assert_equal :allowed, bash("git commit -m #{message.inspect}")
    git("commit", "--quiet", "-m", message)
  end

  def push!
    @origin = Dir.mktmpdir("flow-origin")
    git("init", "--quiet", "--bare", @origin)
    git("remote", "add", "origin", @origin)
    git("push", "--quiet", "-u", "origin", "HEAD")
  end

  # A feature with one built slice, committed and pushed.
  def drafted!
    start!
    write("app/models/invoice.rb", "class Invoice; def dup; end; end\n")
    commit!("Slice")
    push!
  end

  # --- local sessions ------------------------------------------------------

  def test_hooks_do_nothing_outside_cloud_sessions
    @remote = nil
    assert_equal :allowed, edit("app/models/invoice.rb")
    assert_equal :allowed, bash("git push origin HEAD:main")
    assert_equal "", say("start feature duplicate-invoice #92")
    assert_equal "main", git("branch", "--show-current")
  end

  # --- starting and stopping a flow ----------------------------------------

  def test_no_changes_on_main_until_the_maintainer_starts_a_flow
    assert_match(/start feature #<issue>/, edit("app/models/invoice.rb"))
    assert_match(/no flow on branch 'main'/, say("hello"))
  end

  def test_start_feature_needs_its_issue
    assert_match(/needs its issue, as 'start feature #<issue>'/, say("start feature duplicate-invoice"))
    assert_equal "main", git("branch", "--show-current")
  end

  def test_start_feature_creates_branch_and_an_untracked_ledger
    assert_match(/Flow started by the maintainer. .*for issue #92/, start!)
    assert_equal "feature/duplicate-invoice", git("branch", "--show-current")
    assert_equal [92, true], ledger.values_at("issue", "active")
    assert_empty git("status", "--porcelain")
  end

  def test_start_on_a_session_branch_keeps_that_branch
    git("switch", "--quiet", "-c", "claude/session-123")
    say("start fix broken-upload")

    assert_equal "claude/session-123", git("branch", "--show-current")
    assert_equal ["fix", nil], ledger.values_at("mode", "issue")
    assert_equal :allowed, edit("app/models/invoice.rb", agent: "builder")
  end

  def test_a_feature_can_start_from_its_issue_number_alone
    assert_match(/Flow started by the maintainer. .*for issue #92/, say("start feature #92"))
    assert_equal "feature/issue-92", git("branch", "--show-current")
  end

  def test_any_typed_name_becomes_a_branch_safe_name
    say("start feature Show each project’s comment count! #92")
    assert_equal "feature/show-each-projects-comment-count", git("branch", "--show-current")
    assert_equal 92, ledger["issue"]
  end

  def test_a_start_with_no_name_or_issue_says_the_form
    assert_match(/Type 'start feature #<issue>' or 'start fix <name>'/, say("start fix"))
    assert_match(/Type 'start feature #<issue>'/, say("start fix !!"))
    assert_equal "main", git("branch", "--show-current")
  end

  def test_start_refused_with_uncommitted_changes
    write("app/models/invoice.rb", "changed\n")
    assert_match(/uncommitted changes/, say("start feature x #1"))
  end

  def test_a_ledger_from_another_branch_is_no_flow
    start!
    git("switch", "--quiet", "-c", "feature--duplicate-invoice")
    assert_match(/No active flow/, edit("app/models/invoice.rb", agent: "builder"))
    assert_match(/no flow on branch 'feature--duplicate-invoice'/, say("hello"))
  end

  def test_branches_without_a_ledger_are_locked
    git("switch", "--quiet", "-c", "sneaky")
    assert_match(/No active flow/, edit("app/models/invoice.rb", agent: "builder"))
    assert_match(/No active flow/, bash("git commit -m x"))
  end

  def test_stop_flow_locks_the_branch
    start!
    assert_match(/Flow stopped by the maintainer/, say("stop flow"))
    assert_match(/No active flow/, edit("app/models/invoice.rb"))
    assert_match(/is stopped/, say("hello"))
  end

  # --- approvals -----------------------------------------------------------

  def test_approvals_are_recorded_once_and_shown
    assert_match(/no active flow/, say("approve spec"))
    start!
    assert_match(/approve spec: not recorded \(needed only to write db\/migrate/, say("hello"))
    assert_match(/approve spec: recorded/, say("approve spec"))
    assert_match(/already recorded/, say("approve spec"))
    assert_match(/approve draft: recorded/, say("approve draft"))
    assert_equal %w[spec draft], ledger["approvals"].map { _1["name"] }
  end

  # --- file changes --------------------------------------------------------

  def test_app_and_test_files_change_freely_in_a_flow
    start!
    %w[app/models/invoice.rb test/models/invoice_test.rb test/system/invoice_test.rb docs/backlog.md].each do |path|
      assert_equal :allowed, edit(path), path
      assert_equal :allowed, edit(path, agent: "builder"), path
    end
  end

  def test_protected_paths_cant_be_changed
    start!
    %w[.git/config .claude/hooks/flow_gate.rb CLAUDE.md app/CLAUDE.md .github/workflows/ci.yml .env.local
       config/master.key config/credentials.yml.enc].each do |path|
      assert_match(/can't be changed by agents/, edit(path, agent: "builder"), path)
    end
    assert_match(/inside the repository/, edit("../elsewhere.rb"))
  end

  def test_migrations_and_adrs_wait_for_approve_spec
    start!
    %w[db/migrate/20261106_add_copy_to_invoices.rb docs/architecture/0001-invoices.md].each do |path|
      assert_match(/architecture check against the ADRs in docs\/architecture\/.*wait for the maintainer to type 'approve spec'/, edit(path, agent: "builder"), path)
    end
    say("approve spec")
    assert_equal :allowed, edit("db/migrate/20261106_add_copy_to_invoices.rb", agent: "builder")
    assert_equal :allowed, edit("docs/architecture/0001-invoices.md")
  end

  def test_reviewer_never_changes_files
    start!
    assert_match(/never changes files/, edit("app/models/invoice.rb", agent: "reviewer"))
    assert_match(/Only the main session commits/, bash("git commit -m x", agent: "reviewer"))
    assert_equal :allowed, bash("bin/rails test", agent: "reviewer")
  end

  # --- shell ---------------------------------------------------------------

  def test_commits_need_only_the_main_session_and_a_flow_branch
    start!
    write("app/models/invoice.rb", "# unreviewed\n")
    commit!("Slice")
    assert_match(/Only the main session commits/, bash("git commit -m x", agent: "builder"))
  end

  def test_no_commits_or_pushes_on_or_to_main
    assert_match(/No commits on main/, bash("git commit -m x"))
    assert_match(/No pushes to main/, bash("git push"))
    start!
    ["git push origin HEAD:main", "git push origin main", "git -C . push -f origin +HEAD:refs/heads/master"].each do |command|
      assert_match(/No pushes to main or master/, bash(command), command)
    end
    ["git push", "git push -u origin feature/duplicate-invoice", "git push -u origin HEAD"].each do |command|
      assert_equal :allowed, bash(command), command
    end
  end

  def test_denied_commands
    start!
    assert_match(/kamal isn't allowed/, bash("bin/kamal deploy", agent: "builder"))
    assert_match(/production-console isn't allowed/, bash("FOO=1 bin/production-console"))
  end

  def test_everyday_commands_are_allowed
    start!
    [
      "bin/rails test",
      "bin/rails test test/models/invoice_test.rb 2>&1 | tail -20",
      "bundle exec rails test:system",
      "RAILS_ENV=test bin/rails db:prepare",
      "bin/rubocop app",
      "git status && git diff --stat",
      "git log --oneline -5",
      "grep -rn 'gh pr merge' app > /dev/null",
      "gh pr view 12",
      "gh issue view 92",
      "gh api repos/x/y",
      "bin/rails generate migration AddCopyToInvoices",
      "git log -1 && cat <<'EOF'\ngh pr merge 3\nEOF"
    ].each do |command|
      assert_equal :allowed, bash(command, agent: "builder"), command
    end
  end

  def test_commit_message_heredoc_is_allowed
    start!
    command = "git commit -m \"$(cat <<'EOF'\nAdd slice\n\nWith `code` and $(stuff) inside.\nEOF\n)\""
    assert_equal :allowed, bash(command)
  end

  # --- GitHub --------------------------------------------------------------

  def test_github_reads_are_allowed
    start!
    %w[get_pull_request list_commits search_code pull_request_read issue_read].each do |tool|
      assert_equal :allowed, github(tool, {}, agent: "builder"), tool
    end
  end

  def test_merging_and_approving_are_always_refused
    drafted!
    review("ready", "full diff")
    assert_match(/never do them/, github("merge_pull_request", { "pullNumber" => 3 }))
    assert_match(/never do them/, github("pull_request_review_write", { "event" => "APPROVE" }))
    assert_match(/never do them/, pre("mcp__linear__merge_issues", {}, agent: "builder"))
    assert_match(/never do them/, bash("gh -R owner/repo pr merge 3"))
    assert_match(/never do them/, bash("gh pr review 3 --approve"))
  end

  def test_a_draft_pr_opens_without_a_review
    drafted!
    assert_equal :allowed, github("create_pull_request", { "title" => "Duplicate invoice", "draft" => true })
    assert_equal :allowed, bash("gh pr create --draft --fill")
    assert_equal :allowed, github("update_pull_request", { "pullNumber" => 3, "body" => "Criteria" })
    assert_equal :allowed, github("add_reply_to_pull_request_comment", { "pullNumber" => 3, "body" => "Fixed." })
    assert_match(/Only the main session writes to GitHub/, github("create_pull_request", { "draft" => true }, agent: "builder"))
  end

  def test_marking_ready_needs_a_ready_full_diff_review_of_the_pushed_commit
    drafted!
    ready = -> { github("update_pull_request", { "pullNumber" => 3, "draft" => false }) }
    assert_match(/needs a ready 'full diff' review/, ready.call)
    assert_match(/needs a ready 'full diff' review/, github("create_pull_request", { "title" => "x" }))
    assert_match(/needs a ready 'full diff' review/, bash("gh pr ready 3"))
    assert_match(/needs a ready 'full diff' review/, bash("gh pr create --fill"))

    review("ready", "slice")
    assert_match(/needs a ready 'full diff' review/, ready.call)

    write("app/models/invoice.rb", "# changed\n")
    review("ready", "full diff")
    assert_match(/needs a ready 'full diff' review/, ready.call, "not yet pushed")
    commit!("Fix")
    git("push", "--quiet")
    assert_equal :allowed, ready.call
    assert_equal :allowed, bash("gh pr ready 3")

    review("fix first", "full diff")
    assert_match(/needs a ready 'full diff' review/, ready.call, "a later fix first wins")
  end

  def test_only_the_flows_own_issue_can_be_edited
    start!
    assert_equal :allowed, github("issue_write", { "method" => "update", "issue_number" => 92, "body" => "Answers" })
    assert_equal :allowed, github("add_issue_comment", { "issue_number" => 92, "body" => "Q" })
    assert_equal :allowed, bash("gh issue edit 92 --body-file body.md")
    assert_match(/Only issue #92 can be edited/, github("issue_write", { "method" => "update", "issue_number" => 93 }))
    assert_match(/Only issue #92 can be commented on/, github("add_issue_comment", { "issue_number" => 1 }))
    assert_match(/nothing else on GitHub/, bash("gh issue edit 93 --body x"))
    assert_match(/nothing else on GitHub/, bash("gh issue comment 93 --body x"))
  end

  def test_new_issues_need_the_ai_agent_label
    start!
    assert_equal :allowed, github("issue_write", { "method" => "create", "title" => "x", "labels" => ["ai-agent"] })
    assert_match(/needs the ai-agent label/, github("issue_write", { "method" => "create", "title" => "x" }))
    assert_match(/needs the ai-agent label/, github("issue_write", { "method" => "create", "title" => "x", "labels" => ["bug"] }))
    assert_equal :allowed, bash("gh issue create --title x --label ai-agent")
    assert_equal :allowed, bash("gh issue create --title x -l bug,ai-agent")
    assert_equal :allowed, bash(%(gh issue create --title "Split off" --label "ai-agent"))
    assert_equal :allowed, bash("gh issue create --title x -l 'bug,ai-agent'")
    assert_match(/needs the ai-agent label/, bash(%(gh issue create --title x --label "not ai-agent")))
    assert_match(/needs the ai-agent label/, bash("gh issue create --title x"))
    assert_match(/needs the ai-agent label/, bash("gh issue create --title x --label bug"))
  end

  def test_other_github_writes_are_refused
    start!
    %w[create_or_update_file push_files delete_branch create_issue].each do |tool|
      assert_match(/nothing else on GitHub/, github(tool), tool)
    end
  end

  # --- verdicts ------------------------------------------------------------

  def test_copied_template_line_is_not_a_verdict
    start!
    returns("reviewer", "Verdict: ready | fix first | needs the maintainer\nChecked: slice")
    assert_equal "unreadable", ledger["verdicts"].last["verdict"]
  end

  def test_a_verdict_is_read_from_an_object_with_a_content_list
    start!
    returns("reviewer", { "status" => "completed",
                          "content" => [{ "type" => "text", "text" => "Verdict: ready" },
                                        { "type" => "text", "text" => "Checked: interaction" }] })
    assert_equal %w[ready interaction], ledger["verdicts"].last.values_at("verdict", "checked")
  end

  def test_a_verdict_is_read_from_whichever_key_holds_it
    start!
    notice = "The report was delivered as a message."
    {
      "content" => { "content" => [{ "type" => "text", "text" => "Verdict: ready\nChecked: slice" }] },
      "handbackReport" => { "content" => [{ "type" => "text", "text" => notice }],
                            "handbackReport" => "Verdict: fix first\nChecked: slice", "handback" => "Done." },
      "handback" => { "content" => notice, "handbackReport" => { "summary" => "Done." },
                      "handback" => [{ "report" => "Verdict: needs the maintainer" }, { "text" => "Checked: slice" }] }
    }.each do |key, response|
      returns("reviewer", response)
      assert_equal key, ledger["verdicts"].last["source"], key
    end
    assert_equal [["ready", "slice"], ["fix first", "slice"], ["needs the maintainer", "slice"]],
                 ledger["verdicts"].map { _1.values_at("verdict", "checked") }
  end

  def test_an_unreadable_verdict_records_what_was_received
    start!
    returns("reviewer", "x" * 400)
    path = ledger["verdicts"].last["received"].delete_prefix("see ")
    assert_match(/^class: String\nkeys: none\nstart: #{Regexp.escape(("x" * 300).inspect)}$/, File.read(path))
    refute_includes JSON.generate(ledger), "x" * 300
    FileUtils.rm_f(path)
  end

  def test_a_background_review_is_read_from_its_output_file_when_finished
    drafted!
    launch_reviewer
    tree = ledger.dig("pending", "tree")
    assert_match(/hasn't finished/, github("update_pull_request", { "draft" => false }))

    reviewer_runs("Verdict: ready\nChecked: full diff\n\nFindings:\n1. none")
    say("hello")
    assert_equal ["ready", "full diff", "outputFile", tree], ledger["verdicts"].last.values_at("verdict", "checked", "source", "tree")
    assert_nil ledger["pending"]
    assert_equal :allowed, github("update_pull_request", { "draft" => false })
  end

  def test_a_new_review_supersedes_a_pending_one
    start!
    launch_reviewer("a1")
    launch_reviewer("a2")
    assert_equal "a2", ledger.dig("pending", "agent_id")
    review("fix first", "slice")
    assert_nil ledger["pending"]
  end

  def test_other_agents_are_not_checked
    start!
    before = ledger
    assert_empty returns("Explore", "Verdict: ready\nChecked: full diff")
    assert_empty returns("builder", "Verdict: ready\nChecked: full diff")
    assert_equal before, ledger
  end

  # --- Slack ping ----------------------------------------------------------

  def slack_marker = File.join("/tmp/flow-gate", "slack-#{Digest::SHA1.hexdigest(@repo)}")

  # Runs the Stop hook against a local server; returns the posted text, or nil.
  def stop(url: :server, status: "200 OK")
    server = TCPServer.new("127.0.0.1", 0)
    received = Thread.new do
      client = server.accept
      headers = client.gets("\r\n\r\n")
      body = client.read(headers[/content-length: (\d+)/i, 1].to_i)
      client.write("HTTP/1.1 #{status}\r\nContent-Length: 0\r\n\r\n")
      client.close
      JSON.parse(body)["text"]
    end
    url = "http://127.0.0.1:#{server.addr[1]}/hook" if url == :server
    output = hook("Stop", {}, { "SLACK_WEBHOOK_URL" => url })
    assert_equal({}, output)
    received.join(1)&.value
  ensure
    received&.kill
    server&.close
  end

  def test_slack_ping_names_the_feature_issue_and_phase
    start!
    assert_equal "duplicate-invoice #92 · draft: needs a reply", stop
    say("approve draft")
    FileUtils.rm_f(slack_marker)
    assert_equal "duplicate-invoice #92 · interaction: needs a reply", stop
  end

  def test_slack_ping_with_no_flow_needs_a_reply
    assert_equal "main: needs a reply", stop
  end

  def test_slack_ping_for_a_stopped_flow_is_no_active_flow
    start!
    say("stop flow")
    assert_equal "feature/duplicate-invoice: needs a reply", stop
  end

  def test_no_slack_ping_without_a_webhook_or_outside_the_cloud
    assert_nil stop(url: nil)
    @remote = nil
    assert_nil stop
  end

  def test_a_second_stop_within_90_seconds_is_not_pinged
    refute_nil stop
    assert_nil stop
    File.utime(Time.now - 91, Time.now - 91, slack_marker)
    refute_nil stop
  end

  def test_a_failing_slack_request_is_silent
    port = TCPServer.new("127.0.0.1", 0).then { |s| s.addr[1].tap { s.close } }
    assert_nil stop(url: "http://127.0.0.1:#{port}/hook")
    assert_nil stop(url: "not a url")
    refute_nil stop(status: "500 Internal Server Error")
    refute File.exist?(slack_marker), "only a delivered ping starts the 90 seconds"
    refute_nil stop
  end

  # --- protected files -----------------------------------------------------

  BLOCKED = [[2, "Protected files changed. Tell the maintainer."]].freeze
  HOOK_EVENTS = %w[SessionStart UserPromptSubmit PreToolUse PostToolUse].freeze

  # Runs the settings.json flow-gate hook commands for the events; returns their distinct results.
  def run_hook_commands(events = HOOK_EVENTS)
    settings = JSON.parse(File.read(File.join(SOURCE, "settings.json")))
    env = { "CLAUDE_PROJECT_DIR" => @repo, "CLAUDE_CODE_REMOTE" => "true" }
    events.flat_map do |event|
      settings["hooks"].fetch(event).flat_map { _1["hooks"] }.select { _1["command"].include?("flow_gate.rb") }.map do |hook|
        input = JSON.generate({ "hook_event_name" => event })
        _, err, status = Open3.capture3(env, "sh", "-c", hook["command"], chdir: @repo, stdin_data: input)
        [status.exitstatus, err.strip]
      end
    end.uniq
  end

  # Commits the hook, CLAUDE.md and a workflow, and pushes them to a new origin.
  def with_origin
    FileUtils.mkdir_p(File.join(@repo, ".claude/hooks"))
    FileUtils.cp(SCRIPT, File.join(@repo, ".claude/hooks"))
    write("CLAUDE.md", "# Rules\n")
    write(".github/workflows/ci.yml", "on: push\n")
    git("add", "-A")
    git("commit", "--quiet", "-m", "Hooks")
    @origin = Dir.mktmpdir("flow-origin")
    Open3.capture2e("git", "init", "--quiet", "--bare", @origin)
    git("remote", "add", "origin", @origin)
    git("push", "--quiet", "origin", "main")
  end

  def test_hooks_refuse_to_run_when_protected_files_differ_from_main
    assert_equal BLOCKED, run_hook_commands, "no origin"
    with_origin
    assert_equal [[0, ""]], run_hook_commands

    write(".claude/flow/ledgers/feature--other.json", "{}")
    assert_equal [[0, ""]], run_hook_commands, "ledgers are exempt"

    write("CLAUDE.md", "# Rules, loosened\n")
    assert_equal BLOCKED, run_hook_commands, "working tree"
    git("commit", "--quiet", "-am", "Loosen")
    assert_equal BLOCKED, run_hook_commands, "committed"
    git("reset", "--quiet", "--hard", "origin/main")

    write(".github/workflows/ci.yml", "on: [push, pull_request]\n")
    assert_equal BLOCKED, run_hook_commands, ".github"
    git("checkout", "--quiet", "--", ".github")

    write(".claude/skills/new/SKILL.md", "# New\n")
    assert_equal BLOCKED, run_hook_commands, "untracked"
  end

  # What the flow-gate hook command for the event adds to the session's context.
  def session_told(event)
    settings = JSON.parse(File.read(File.join(SOURCE, "settings.json")))
    hook = settings["hooks"].fetch(event).flat_map { _1["hooks"] }.find { _1["command"].include?("flow_gate.rb") }
    env = { "CLAUDE_PROJECT_DIR" => @repo, "CLAUDE_CODE_REMOTE" => "true" }
    out, = Open3.capture3(env, "sh", "-c", hook["command"], chdir: @repo,
                          stdin_data: JSON.generate({ "hook_event_name" => event }))
    out.strip.empty? ? nil : JSON.parse(out).dig("hookSpecificOutput", "additionalContext")
  end

  def test_the_session_is_told_the_flow_status_at_session_start_and_on_each_prompt
    with_origin
    %w[SessionStart UserPromptSubmit].each do |event|
      assert_includes session_told(event).to_s, "Flow: no flow", event
    end
  end

  def test_session_start_runs_the_gate_only_after_the_check_passes
    with_origin
    write("CLAUDE.md", "# Rules, loosened\n")
    assert_equal BLOCKED, run_hook_commands(%w[SessionStart])
    assert_nil session_told("SessionStart"), "ran despite the failed check"

    git("checkout", "--quiet", "--", "CLAUDE.md")
    assert_equal [[0, ""]], run_hook_commands(%w[SessionStart])
    assert_includes session_told("SessionStart").to_s, "Flow: no flow"
  end

  # --- logging and failure -------------------------------------------------

  def test_blocked_actions_are_logged_for_the_reviewer
    start!
    reason = bash("bin/kamal deploy", agent: "builder")
    assert_match(/If a block names a way forward, take it and note the block in the PR notes/, reason)
    entry = ledger["log"].last
    assert_equal "blocked", entry["event"]
    assert_equal "builder", entry["agent"]
  end

  def test_non_ascii_input_is_read_as_utf8_whatever_the_locale
    output = hook("PreToolUse", { "tool_name" => "Bash", "tool_input" => { "command" => "bin/kamal deploy “—”" } },
                  { "LANG" => "C", "LC_ALL" => "C" })
    assert_equal "deny", output.dig("hookSpecificOutput", "permissionDecision")
  end

  def test_a_broken_ledger_fails_closed
    start!
    File.write(Dir[File.join(@repo, ".claude/flow/ledgers/feature--*.json")].first, "{ not json")
    assert_match(/flow hook failed/, edit("app/models/invoice.rb", agent: "builder"))
  end
end
