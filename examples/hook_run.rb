# Feeds .claude/hooks/flow_gate.rb the hook events Claude Code would send, in a
# throwaway repo, and prints each request and the hook's verbatim reply as
# markdown. Run from the repo root: ruby examples/hook_run.rb > examples/hook-run.md
require "json"; require "open3"; require "tmpdir"; require "fileutils"
SRC = File.expand_path("..", __dir__)
repo = Dir.mktmpdir("demo-app"); origin = Dir.mktmpdir("demo-origin")
FileUtils.mkdir_p("#{repo}/.claude/flow"); FileUtils.mkdir_p("#{repo}/app/models")
FileUtils.cp("#{SRC}/.claude/flow/config.json", "#{repo}/.claude/flow/")
FileUtils.cp("#{SRC}/.gitignore", repo)
File.write("#{repo}/app/models/invoice.rb", "class Invoice < ApplicationRecord\nend\n")
g = ->(*a) { Open3.capture2e("git", "-C", repo, *a).first }
g.("init", "-q", "--initial-branch=main"); g.("config", "user.email", "test@example.com"); g.("config", "user.name", "Test")
g.("add", "-A"); g.("commit", "-qm", "Initial"); Open3.capture2e("git", "init", "-q", "--bare", origin); g.("remote", "add", "origin", origin); g.("push", "-q", "-u", "origin", "main")
ENVV = { "CLAUDE_PROJECT_DIR" => repo, "CLAUDE_CODE_REMOTE" => "true" }
def hook(event, fields)
  out, = Open3.capture2(ENVV, "ruby", "#{SRC}/.claude/hooks/flow_gate.rb", stdin_data: JSON.generate({ "hook_event_name" => event }.merge(fields)))
  return "(allowed)" if out.strip.empty?
  h = JSON.parse(out)["hookSpecificOutput"]
  h["permissionDecision"] == "deny" ? "DENIED: #{h['permissionDecisionReason']}" : h["additionalContext"]
end
def pre(tool, input, agent = nil) = hook("PreToolUse", { "tool_name" => tool, "tool_input" => input }.merge(agent ? { "agent_type" => agent } : {}))
def show(who, what, reply) = puts("**#{who}:** #{what}\n\n```text\n#{reply.gsub("#{ENVV['CLAUDE_PROJECT_DIR']}/", "")}\n```\n\n")
puts <<~MD
  # A run of the flow gate

  The real replies of `.claude/hooks/flow_gate.rb` to the hook events of one
  feature, [issue #42](issue.md), in a throwaway repo. Regenerate it with
  `ruby examples/hook_run.rb > examples/hook-run.md`.

MD
show("Session starts", "on `main`", hook("SessionStart", {}))
show("Builder", "edits `app/models/invoice.rb`", pre("Edit", { "file_path" => "#{repo}/app/models/invoice.rb" }, "builder"))
show("Maintainer types", "`start feature overdue-invoices #42`", hook("UserPromptSubmit", { "prompt" => "start feature overdue-invoices #42" }))
show("Builder", "writes `db/migrate/20261112_add_due_on_to_invoices.rb`", pre("Write", { "file_path" => "#{repo}/db/migrate/20261112_add_due_on_to_invoices.rb" }, "builder"))
show("Builder", "edits `CLAUDE.md`", pre("Edit", { "file_path" => "#{repo}/CLAUDE.md" }, "builder"))
show("Builder", "edits `app/models/invoice.rb`", pre("Edit", { "file_path" => "#{repo}/app/models/invoice.rb" }, "builder"))
show("Builder", "runs `git commit -m \"Overdue scope\"`", pre("Bash", { "command" => "git commit -m \"Overdue scope\"" }, "builder"))
show("Builder", "runs `bin/kamal deploy`", pre("Bash", { "command" => "bin/kamal deploy" }, "builder"))
show("Reviewer", "edits `app/models/invoice.rb`", pre("Edit", { "file_path" => "#{repo}/app/models/invoice.rb" }, "reviewer"))
File.write("#{repo}/app/models/invoice.rb", "class Invoice < ApplicationRecord\n  scope :overdue, -> { where(paid_at: nil).where(due_on: ...Date.current) }\nend\n")
show("Coordinator", "runs `git commit -m \"Overdue scope\"`", pre("Bash", { "command" => "git commit -m \"Overdue scope\"" }))
g.("commit", "-qam", "Overdue scope")
show("Coordinator", "runs `git push origin HEAD:main`", pre("Bash", { "command" => "git push origin HEAD:main" }))
show("Coordinator", "runs `git push -u origin HEAD`", pre("Bash", { "command" => "git push -u origin HEAD" }))
g.("push", "-q", "-u", "origin", "HEAD")
show("Coordinator", "opens a draft PR (`create_pull_request`, `draft: true`)", pre("mcp__github__create_pull_request", { "title" => "Overdue invoices", "draft" => true }))
show("Coordinator", "marks the PR ready (`update_pull_request`, `draft: false`)", pre("mcp__github__update_pull_request", { "pullNumber" => 7, "draft" => false }))
hook("PostToolUse", { "tool_name" => "Agent", "tool_input" => { "subagent_type" => "reviewer" }, "tool_response" => "Verdict: ready\nChecked: full diff\n\nFindings:\n1. None" })
show("Reviewer returns", "`Verdict: ready` / `Checked: full diff` on the pushed commit; the coordinator marks the PR ready again", pre("mcp__github__update_pull_request", { "pullNumber" => 7, "draft" => false }))
show("Coordinator", "merges (`merge_pull_request`)", pre("mcp__github__merge_pull_request", { "pullNumber" => 7 }))
FileUtils.rm_rf([repo, origin])
