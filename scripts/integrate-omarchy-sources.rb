#!/usr/bin/env ruby
# frozen_string_literal: true

require "xcodeproj"
require "set"
require "fileutils"

project_path = File.expand_path("../RiftVM/RiftVM.xcodeproj", __dir__)
source_root = File.expand_path("../RiftVM/RiftVM/Omarchy", __dir__)
project = Xcodeproj::Project.open(project_path)
target = project.targets.find { |item| item.name == "RiftVM" }
abort "RiftVM target not found" unless target

group = project.main_group.groups.find { |item| item.display_name == "Omarchy Integration" }
group ||= project.main_group.new_group("Omarchy Integration", source_root)

Dir.glob(File.join(source_root, "*.swift")).sort.each do |path|
  name = File.basename(path)
  reference = group.files.find { |item| item.display_name == name }
  reference ||= group.new_file(name)
  target.add_file_references([reference]) unless target.source_build_phase.files_references.include?(reference)
end

core_root = File.expand_path("../RiftVM/RiftVM/Core/VMKit", __dir__)
core_group = project.main_group.groups.find { |item| item.display_name == "Unified VMKit" }
core_group ||= project.main_group.new_group("Unified VMKit", core_root)
compiled_paths = target.source_build_phase.files_references.map do |reference|
  File.expand_path(reference.real_path.to_s) rescue nil
end.compact.to_set

Dir.glob(File.join(core_root, "**/*.swift")).sort.each do |path|
  next if compiled_paths.include?(File.expand_path(path))

  relative_path = path.delete_prefix("#{core_root}/")
  reference = core_group.files.find { |item| item.path == relative_path }
  reference ||= core_group.new_file(relative_path)
  target.add_file_references([reference])
end

test_root = File.expand_path("../Tests/RiftVMIntegrationTests", __dir__)
test_target = project.targets.find { |item| item.name == "RiftVMIntegrationTests" }
unless test_target
  test_target = project.new_target(:unit_test_bundle, "RiftVMIntegrationTests", :osx, "27.0")
  test_target.add_dependency(target)
end
test_target.build_configurations.each do |configuration|
  configuration.build_settings["SWIFT_VERSION"] = "5.0"
  configuration.build_settings["PRODUCT_MODULE_NAME"] = "RiftVMIntegrationTests"
  configuration.build_settings["PRODUCT_NAME"] = "RiftVMIntegrationTests"
  configuration.build_settings["EXECUTABLE_NAME"] = "RiftVMIntegrationTests"
  configuration.build_settings["PRODUCT_BUNDLE_IDENTIFIER"] = "com.riftvm.app.integration-tests"
  configuration.build_settings["CODE_SIGN_STYLE"] = "Automatic"
  configuration.build_settings["DEVELOPMENT_TEAM"] = "YPV49M8592"
  configuration.build_settings["GENERATE_INFOPLIST_FILE"] = "YES"
  configuration.build_settings["TEST_HOST"] = "$(BUILT_PRODUCTS_DIR)/RiftVM.app/Contents/MacOS/RiftVM"
  configuration.build_settings["BUNDLE_LOADER"] = "$(TEST_HOST)"
end
test_group = project.main_group.groups.find { |item| item.display_name == "RiftVM Integration Tests" }
test_group ||= project.main_group.new_group("RiftVM Integration Tests", test_root)
Dir.glob(File.join(test_root, "*.swift")).sort.each do |path|
  name = File.basename(path)
  reference = test_group.files.find { |item| item.display_name == name }
  reference ||= test_group.new_file(name)
  test_target.add_file_references([reference]) unless test_target.source_build_phase.files_references.include?(reference)
end

# Drop references to files that no longer exist, so deleting a source file is
# enough to take it out of the app.
project.targets.each do |item|
  item.source_build_phase.files.dup.each do |build_file|
    reference = build_file.file_ref
    next unless reference
    path = (reference.real_path.to_s rescue nil)
    next if path.nil? || File.exist?(path)
    item.source_build_phase.remove_build_file(build_file)
    reference.remove_from_project
  end
end

# Schemes are shared and checked in under xcshareddata/xcschemes, so a fresh
# clone can build every target without running this script. Only a target that
# has no shared scheme yet gets one here; an existing scheme is never rewritten,
# which keeps the worktree clean whichever xcodeproj version runs this.
shared_schemes_dir = Xcodeproj::XCScheme.shared_data_dir(project_path)
FileUtils.mkdir_p(shared_schemes_dir)
project.targets.each do |item|
  shared_scheme = File.join(shared_schemes_dir, "#{item.name}.xcscheme")
  unless File.exist?(shared_scheme)
    scheme = Xcodeproj::XCScheme.new
    scheme_test_target = item.respond_to?(:test_target_type?) && item.test_target_type? ? item : nil
    scheme_launchable = item.respond_to?(:launchable_target_type?) && item.launchable_target_type?
    scheme.configure_with_targets(item, scheme_test_target, launch_target: scheme_launchable)
    scheme.save_as(project_path, item.name, true)
  end
  # Earlier versions of this script generated per-user copies of the same
  # schemes. Next to a shared scheme they show up twice in `xcodebuild -list`,
  # so drop those generated copies.
  Dir.glob(File.join(project_path, "xcuserdata", "*.xcuserdatad", "xcschemes", "#{item.name}.xcscheme")).each do |path|
    File.delete(path)
  end
end
project.save
