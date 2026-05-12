#!/usr/bin/env ruby
require "fileutils"
require "open3"
require "tmpdir"
require "xcodeproj"

ROOT = File.expand_path("..", __dir__)
PROJECT_PATH = File.join(ROOT, "Aileen4DisasterRelief.xcodeproj")
DEVELOPMENT_TEAM = "FSYXWNUDDW"
TARGET_NAME = "Aileen4DisasterRelief"
PRESERVED_TARGET_BUILD_SETTING_DEFAULTS = {
  "PRODUCT_BUNDLE_IDENTIFIER" => "de.ndurner.Aileen4DisasterRelief",
  "MARKETING_VERSION" => "1.0",
  "CURRENT_PROJECT_VERSION" => "1.0"
}.freeze

def preserved_target_build_settings(project_path)
  project = tracked_project(project_path) || existing_project(project_path)
  return {} unless project

  target = project.targets.find { |candidate| candidate.name == TARGET_NAME }
  return {} unless target

  target.build_configurations.each_with_object({}) do |config, preserved|
    preserved[config.name] = PRESERVED_TARGET_BUILD_SETTING_DEFAULTS.each_with_object({}) do |(key, fallback), settings|
      settings[key] = config.build_settings[key] || fallback
    end
  end
end

def tracked_project(project_path)
  repo_root, status = Open3.capture2("git", "-C", ROOT, "rev-parse", "--show-toplevel")
  return unless status.success?

  repo_root = repo_root.strip
  relative_pbxproj_path = File.join(project_path.delete_prefix("#{repo_root}/"), "project.pbxproj")
  pbxproj_contents, pbxproj_status = Open3.capture2("git", "-C", repo_root, "show", "HEAD:#{relative_pbxproj_path}")
  return unless pbxproj_status.success?

  Dir.mktmpdir do |tmpdir|
    tmp_project_path = File.join(tmpdir, File.basename(project_path))
    FileUtils.mkdir_p(tmp_project_path)
    File.write(File.join(tmp_project_path, "project.pbxproj"), pbxproj_contents)
    return Xcodeproj::Project.open(tmp_project_path)
  end
end

def existing_project(project_path)
  return unless File.exist?(project_path)

  Xcodeproj::Project.open(project_path)
end

preserved_build_settings = preserved_target_build_settings(PROJECT_PATH)

FileUtils.rm_rf(PROJECT_PATH)
project = Xcodeproj::Project.new(PROJECT_PATH)

app_target = project.new_target(:application, TARGET_NAME, :ios, "17.0")
app_target.product_reference.name = "#{TARGET_NAME}.app"

project.root_object.attributes["TargetAttributes"] ||= {}
project.root_object.attributes["TargetAttributes"][app_target.uuid] = {
  "ProvisioningStyle" => "Automatic",
  "DevelopmentTeam" => DEVELOPMENT_TEAM
}

main_group = project.main_group
app_group = main_group.new_group("Aileen4DisasterRelief", "Aileen4DisasterRelief")
resources_group = app_group.new_group("Resources", "Aileen4DisasterRelief/Resources")
support_group = app_group.new_group("Support", "Aileen4DisasterRelief/Support")
sources_group = main_group.new_group("Sources", "Aileen4DisasterRelief/Sources")
appmodule_group = sources_group.new_group("AppModule", "AppModule")
overlay_lab_group = sources_group.new_group("OverlayLab", "OverlayLab")
bridge_group = sources_group.new_group("LiteRTLMBridge", "LiteRTLMBridge")

Dir.children(File.join(ROOT, "Aileen4DisasterRelief", "Sources", "AppModule"))
  .select { |filename| filename.end_with?(".swift") }
  .sort
  .each do |filename|
  reference = appmodule_group.new_file("Aileen4DisasterRelief/Sources/AppModule/#{filename}")
  reference.source_tree = "SOURCE_ROOT"
  app_target.add_file_references([reference])
end

Dir.children(File.join(ROOT, "Aileen4DisasterRelief", "Sources", "OverlayLab"))
  .select { |filename| filename.end_with?(".swift") }
  .sort
  .each do |filename|
  reference = overlay_lab_group.new_file("Aileen4DisasterRelief/Sources/OverlayLab/#{filename}")
  reference.source_tree = "SOURCE_ROOT"
  app_target.add_file_references([reference])
end

bridge_ref = bridge_group.new_file("Aileen4DisasterRelief/Sources/LiteRTLMBridge/LiteRTLMBridge.mm")
bridge_ref.source_tree = "SOURCE_ROOT"
app_target.add_file_references([bridge_ref])

bridging_header_ref = support_group.new_file("Aileen4DisasterRelief/Support/Aileen4DisasterRelief-Bridging-Header.h")
bridging_header_ref.source_tree = "SOURCE_ROOT"

asset_ref = resources_group.new_file("Aileen4DisasterRelief/Resources/Assets.xcassets")
asset_ref.source_tree = "SOURCE_ROOT"
app_target.resources_build_phase.add_file_reference(asset_ref)

google_vendor_group = main_group.new_group("GoogleAIEdge", "ThirdParty/GoogleAIEdge")
litert_ref = google_vendor_group.new_file("ThirdParty/GoogleAIEdge/LiteRTLM.xcframework")
constraint_ref = google_vendor_group.new_file("ThirdParty/GoogleAIEdge/GemmaModelConstraintProvider.xcframework")
metal_ref = google_vendor_group.new_file("ThirdParty/GoogleAIEdge/LiteRtMetalAccelerator.xcframework")
[litert_ref, constraint_ref, metal_ref].each { |ref| ref.source_tree = "SOURCE_ROOT" }

app_target.frameworks_build_phase.add_file_reference(litert_ref)
app_target.frameworks_build_phase.add_file_reference(constraint_ref)
app_target.frameworks_build_phase.add_file_reference(metal_ref)

embed_phase = project.new(Xcodeproj::Project::Object::PBXCopyFilesBuildPhase)
embed_phase.name = "Embed Frameworks"
embed_phase.symbol_dst_subfolder_spec = :frameworks
app_target.build_phases << embed_phase
[
  embed_phase.add_file_reference(constraint_ref, true),
  embed_phase.add_file_reference(metal_ref, true)
].each do |build_file|
  build_file.settings = {
    "ATTRIBUTES" => ["CodeSignOnCopy", "RemoveHeadersOnCopy"]
  }
end

app_target.build_configurations.each do |config|
  preserved_settings = PRESERVED_TARGET_BUILD_SETTING_DEFAULTS.merge(preserved_build_settings.fetch(config.name, {}))

  config.build_settings["PRODUCT_BUNDLE_IDENTIFIER"] = preserved_settings["PRODUCT_BUNDLE_IDENTIFIER"]
  config.build_settings["MARKETING_VERSION"] = preserved_settings["MARKETING_VERSION"]
  config.build_settings["CURRENT_PROJECT_VERSION"] = preserved_settings["CURRENT_PROJECT_VERSION"]
  config.build_settings["SWIFT_VERSION"] = "6.0"
  config.build_settings["CODE_SIGN_STYLE"] = "Automatic"
  config.build_settings["DEVELOPMENT_TEAM"] = DEVELOPMENT_TEAM
  config.build_settings["CODE_SIGN_IDENTITY"] = "Apple Development"
  config.build_settings["GENERATE_INFOPLIST_FILE"] = "YES"
  config.build_settings["INFOPLIST_KEY_CFBundleDisplayName"] = "Aileen 4"
  config.build_settings["INFOPLIST_KEY_UIApplicationSceneManifest_Generation"] = "YES"
  config.build_settings["INFOPLIST_KEY_UILaunchScreen_Generation"] = "YES"
  config.build_settings["INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone"] = "UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight"
  config.build_settings["INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad"] = "UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight"
  config.build_settings["INFOPLIST_KEY_NSPhotoLibraryUsageDescription"] = "Select disaster-relief media assets."
  config.build_settings["INFOPLIST_KEY_LSSupportsOpeningDocumentsInPlace"] = "YES"
  config.build_settings["INFOPLIST_KEY_UIFileSharingEnabled"] = "YES"
  config.build_settings["ASSETCATALOG_COMPILER_APPICON_NAME"] = "AppIcon"
  config.build_settings["ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME"] = "AccentColor"
  config.build_settings["IPHONEOS_DEPLOYMENT_TARGET"] = "17.0"
  config.build_settings["TARGETED_DEVICE_FAMILY"] = "1,2"
  config.build_settings["SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD"] = "YES"
  config.build_settings["EXCLUDED_ARCHS[sdk=iphonesimulator*]"] = "x86_64"
  config.build_settings["ENABLE_USER_SCRIPT_SANDBOXING"] = "NO"
  config.build_settings["SWIFT_OBJC_BRIDGING_HEADER"] = "Aileen4DisasterRelief/Support/Aileen4DisasterRelief-Bridging-Header.h"
  config.build_settings["CLANG_CXX_LANGUAGE_STANDARD"] = "gnu++20"
  config.build_settings["GCC_PREPROCESSOR_DEFINITIONS"] = ["$(inherited)", "GEMMA_LITERTLM_LINKED=1"]
  config.build_settings["OTHER_LDFLAGS"] = ["$(inherited)"]
  config.build_settings["OTHER_LDFLAGS[sdk=iphoneos*]"] = [
    "$(inherited)",
    "-force_load",
    "$(PROJECT_DIR)/ThirdParty/GoogleAIEdge/LiteRTLM.xcframework/ios-arm64/LiteRTLM.framework/LiteRTLM"
  ]
  config.build_settings["OTHER_LDFLAGS[sdk=iphonesimulator*]"] = [
    "$(inherited)",
    "-force_load",
    "$(PROJECT_DIR)/ThirdParty/GoogleAIEdge/LiteRTLM.xcframework/ios-arm64-simulator/LiteRTLM.framework/LiteRTLM"
  ]
  config.build_settings["LD_RUNPATH_SEARCH_PATHS"] = ["$(inherited)", "@executable_path/Frameworks"]
end

project.save
