require 'erb'
require 'master_manipulator'
require 'dsc_utils'
test_name 'Cannot load a DSC resource from PSModulePath by ModuleName when multiple versions exist'

# Init
local_files_root_path = ENV['MANIFESTS'] || 'tests/manifests'
# DSC runs in system context / cannot use users module path
pshome_modules_path = 'Windows/system32/WindowsPowerShell/v1.0/Modules'
program_files_modules_path = 'Program\ Files/WindowsPowerShell/Modules'

# Manifest
fake_name = SecureRandom.uuid

# Teardown
teardown do
  confine_block(:to, :platform => 'windows') do
    step 'Remove Test Artifacts'
    on(agents, <<-CYGWIN)
rm -rf /cygdrive/c/#{pshome_modules_path}/PuppetFakeResource
rm -rf /cygdrive/c/#{program_files_modules_path}/PuppetFakeResource
rm -rf /cygdrive/c/#{fake_name}
CYGWIN
  end

  uninstall_fake_reboot_resource(master)
end

# Setup
step 'Copy Test Type DSC resources'
install_fake_reboot_resource(master)

step 'Clear "site.pp" on Master'
inject_site_pp(master, get_site_pp_path(master), create_site_pp(master))

confine_block(:to, :platform => 'windows') do
  step 'Sync DSC resource implementations to agents'
  on(agents, puppet('agent -t --environment production'), :acceptable_exit_codes => [0,2])

  step 'Copy PuppetFakeResource implementations to system PSModulePath locations'
  installed_path = '/cygdrive/c/ProgramData/PuppetLabs/puppet/cache/lib/puppet_x/dsc_resources'

  # put PuppetFakeResource v1 in $PSHome\Modules
  on(agents, <<-CYGWIN)
cp --recursive #{installed_path}/PuppetFakeResource /cygdrive/c/#{pshome_modules_path}
# copying from Puppet pluginsync directory includes NULL SID and other wonky perms, so reset
icacls "C:\\#{pshome_modules_path.gsub('/', '\\')}\\PuppetFakeResource" /reset /T
CYGWIN

  # put PuppetFakeResource v2 in $Env:Program Files\WindowsPowerShell\Modules
  # noting that the parent folder *must* be PuppetFakeResource, not PuppetFakeResource2
  on(agents, <<-CYGWIN)
mkdir -p /cygdrive/c/#{program_files_modules_path}/PuppetFakeResource
cp --recursive #{installed_path}/PuppetFakeResource2/* /cygdrive/c/#{program_files_modules_path}/PuppetFakeResource
# copying from Puppet pluginsync directory includes NULL SID and other wonky perms, so reset
icacls "C:\\#{program_files_modules_path.gsub('\\', '').gsub('/', '\\')}\\PuppetFakeResource" /reset /T
CYGWIN

  # verify DSC shows 2 installed copies of the resource
  check_dsc_resources = 'Get-DscResource PuppetFakeResource | Measure-Object | Select -ExpandProperty Count'
  on(agents, powershell(check_dsc_resources, {'EncodedCommand' => true}), :acceptable_exit_codes => [0]) do |result|
    assert_match(/^2$/, result.stdout, 'Expected 2 copies of PuppetFakeResource to be installed!')
  end
end

# Test that DSC won't resolve ambiguous resource reference
test_file_contents = SecureRandom.uuid
dsc_ambiguous_manifest = <<-MANIFEST
dsc {'#{fake_name}':
  dsc_resource_name => 'PuppetFakeResource',
  # NOTE: relies on finding resource in system parts of $ENV:PSModulePath
  dsc_resource_module_name => 'PuppetFakeResource',
  dsc_resource_properties => {
    ensure          => 'present',
    importantstuff  => '#{test_file_contents}',
    destinationpath => 'C:\\#{fake_name}'
  }
}
MANIFEST

step 'Inject "site.pp" on Master'
site_pp = create_site_pp(master, :manifest => dsc_ambiguous_manifest)
inject_site_pp(master, get_site_pp_path(master), site_pp)

confine_block(:to, :platform => 'windows') do
  agents.each do |agent|
    step 'Run Puppet Agent'

    # this scenario fails as DSC doesn't know which version to use
    on(agent, puppet('agent -t --environment production'), :acceptable_exit_codes => [0,2,4]) do |result|
      error_msg = /Stage\[main\]\/Main\/Node\[default\]\/Dsc\[#{fake_name}\]\: Could not evaluate\: Resource PuppetFakeResource was not found\./
      assert_match(error_msg, result.stderr, 'Expected Invoke-DscResource error missing!')
    end

    step 'Verify that the File is Absent.'
    # if this file exists, resource executed
    on(agent, "test -f /cygdrive/c/#{fake_name}", :acceptable_exit_codes => [1])
  end
end

# Test that DSC works with versioned reference
dsc_versioned_manifest = <<-MANIFEST
dsc {'#{fake_name}':
  dsc_resource_name => 'PuppetFakeResource',
  # NOTE: relies on finding resource in system parts of $ENV:PSModulePath
  dsc_resource_module_name => 'PuppetFakeResource',
  dsc_resource_module_version => '2.0',
  dsc_resource_properties => {
    ensure          => 'present',
    importantstuff  => '#{test_file_contents}',
    destinationpath => 'C:\\#{fake_name}'
  }
}
MANIFEST

step 'Inject "site.pp" on Master'
site_pp = create_site_pp(master, :manifest => dsc_versioned_manifest)
inject_site_pp(master, get_site_pp_path(master), site_pp)

# Tests
confine_block(:to, :platform => 'windows') do
  agents.each do |agent|
    step 'Run Puppet Agent'

    # this scenario expectedly fails as DSC doesn't know which version to use
    on(agent, puppet('agent -t --environment production'), :acceptable_exit_codes => [1]) do |result|
      expect_failure('Cannot yet specify module version until MODULES-5845 implemented') do
        assert_no_match(/Error:/, result.stderr, 'Unexpected error was detected!')
      end
    end

    step 'Verify Results'
    # PuppetFakeResource always overwrites file at this path
    # PuppetFakeResourc2 2.0 appends "v2" to the written file before "ImportantStuff"
    on(agent, "cat /cygdrive/c/#{fake_name}", :acceptable_exit_codes => [1]) do |result|
      expect_failure('Cannot yet execute PuppetFakeResource 2.0 until MODULES-5845 implemented') do
        assert_match(/^v2#{test_file_contents}/, result.stdout, 'PuppetFakeResource File contents incorrect!')
      end
    end
  end
end
