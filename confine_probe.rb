# Real confinement test driving the actual SandboxBackend argv (#290).
require_relative "lib/rubino"
require "fileutils"

WORK = "/tmp/ws"; FileUtils.mkdir_p(WORK)
HOME = ENV["HOME"]

# Force Linux + network-off, sandbox on, workspace_write. We build the argv
# from the REAL backend, then spawn it exactly like ShellTool would.
def run(cmd, roots:)
  b = Rubino::Execution::SandboxBackend.new(mode: :workspace_write)
  argv = b.argv(cmd, writable_roots: roots)
  pid = Process.spawn(*argv, chdir: WORK, pgroup: true,
                      out: "/dev/null", err: "/dev/null")
  _, st = Process.waitpid2(pid)
  st.exitstatus
end

roots = [WORK]
puts "available?=#{Rubino::Execution::SandboxBackend.available?} host=#{Rubino::Execution::SandboxBackend.host_os}"

# 1. write INSIDE workspace -> should SUCCEED (exit 0)
in_rc = run("echo hi > #{WORK}/inside.txt", roots: roots)
puts "WRITE_INSIDE  exit=#{in_rc} (expect 0)  file_exists=#{File.exist?("#{WORK}/inside.txt")}"

# 2. write OUTSIDE (HOME) -> should be DENIED (non-zero)
out_rc = run("echo evil > #{HOME}/evil.txt", roots: roots)
puts "WRITE_HOME    exit=#{out_rc} (expect !=0)  file_exists=#{File.exist?("#{HOME}/evil.txt")}"

# 3. write /etc -> should be DENIED
etc_rc = run("echo x > /etc/rubino_evil", roots: roots)
puts "WRITE_ETC     exit=#{etc_rc} (expect !=0)  file_exists=#{File.exist?("/etc/rubino_evil")}"

# 4. network egress with network disabled -> should FAIL
net_rc = run("getent hosts example.com >/dev/null 2>&1 && curl -sS --max-time 5 http://1.1.1.1 >/dev/null", roots: roots)
puts "NETWORK_OFF   exit=#{net_rc} (expect !=0)"

# 5. workspace OUTSIDE /tmp (proves the per-root bind, not just the /tmp bind)
WORK2 = "/opt/ws2"; FileUtils.mkdir_p(WORK2)
in2 = run("echo hi > #{WORK2}/inside.txt", roots: [WORK2])
puts "WRITE_OPT_WS  exit=#{in2} (expect 0)  file_exists=#{File.exist?("#{WORK2}/inside.txt")}"
