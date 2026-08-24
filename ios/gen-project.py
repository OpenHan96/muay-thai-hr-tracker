#!/usr/bin/env python3
"""Regenerate FightHR.xcodeproj/project.pbxproj from the Swift files in
FightHR/Sources. Run after adding/removing source files:  python3 gen-project.py

Keeps the Sources group path correct and bakes in the signing team so
regenerating does not wipe Xcode's signing config.
"""
import os, hashlib

DEVELOPMENT_TEAM = "9RYDT6H7V4"   # Eugene Han — update if the Apple team changes
BUNDLE_ID = "com.fighthr.app"
MARKETING_VERSION = "1.6"
CURRENT_PROJECT_VERSION = "3"
SENTRY_VERSION = "9.24.0"
SENTRY_DSN = "https://06b6946af22dd3a4531d580a1157239e@o4511966563926016.ingest.de.sentry.io/4511966567792720"
HERE = os.path.dirname(os.path.abspath(__file__))
os.chdir(HERE)

SOURCES = sorted(os.path.basename(f) for f in os.listdir("FightHR/Sources") if f.endswith(".swift"))
def oid(s): return hashlib.md5(s.encode()).hexdigest()[:24].upper()

file_refs={s:oid("fref-"+s) for s in SOURCES}; build_files={s:oid("bf-"+s) for s in SOURCES}
ASSET="Assets.xcassets"; INFO="Info.plist"
file_refs[ASSET]=oid("fref-assets"); build_files[ASSET]=oid("bf-assets"); file_refs[INFO]=oid("fref-info")
PRODUCT=oid("product-app");PROJECT=oid("project-root");MAINGROUP=oid("group-main")
SRCGROUP=oid("group-src");SOURCESGROUP=oid("group-sources-sub");PRODGROUP=oid("group-products")
TARGET=oid("target-app");SOURCES_PHASE=oid("phase-sources");RES_PHASE=oid("phase-resources")
FRAMEWORKS_PHASE=oid("phase-frameworks");CFG_LIST_PROJ=oid("cfglist-proj");CFG_LIST_TGT=oid("cfglist-tgt")
CFG_PROJ_DEBUG=oid("cfg-proj-debug");CFG_PROJ_REL=oid("cfg-proj-rel");CFG_TGT_DEBUG=oid("cfg-tgt-debug");CFG_TGT_REL=oid("cfg-tgt-rel")
SENTRY_PACKAGE=oid("package-sentry");SENTRY_PRODUCT=oid("product-sentry");SENTRY_BUILD=oid("build-sentry")

bf="\n".join(f"\t\t{build_files[s]} /* {s} in Sources */ = {{isa = PBXBuildFile; fileRef = {file_refs[s]} /* {s} */; }};" for s in SOURCES)
bf+=f"\n\t\t{build_files[ASSET]} /* {ASSET} in Resources */ = {{isa = PBXBuildFile; fileRef = {file_refs[ASSET]} /* {ASSET} */; }};"
bf+=f"\n\t\t{SENTRY_BUILD} /* SentrySPM in Frameworks */ = {{isa = PBXBuildFile; productRef = {SENTRY_PRODUCT} /* SentrySPM */; }};"
fr="\n".join(f"\t\t{file_refs[s]} /* {s} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {s}; sourceTree = \"<group>\"; }};" for s in SOURCES)
fr+=f"\n\t\t{file_refs[ASSET]} /* {ASSET} */ = {{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = {ASSET}; sourceTree = \"<group>\"; }};"
fr+=f"\n\t\t{file_refs[INFO]} /* {INFO} */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = {INFO}; sourceTree = \"<group>\"; }};"
fr+=f"\n\t\t{PRODUCT} /* FightHR.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = FightHR.app; sourceTree = BUILT_PRODUCTS_DIR; }};"
src_children="\n".join(f"\t\t\t\t{file_refs[s]} /* {s} */," for s in SOURCES)
phase_files="\n".join(f"\t\t\t\t{build_files[s]} /* {s} in Sources */," for s in SOURCES)

def tgt_cfg(oid_, name):
    return f"""		{oid_} /* {name} */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = {CURRENT_PROJECT_VERSION};
				DEVELOPMENT_TEAM = {DEVELOPMENT_TEAM};
				ENABLE_PREVIEWS = YES;
				GENERATE_INFOPLIST_FILE = NO;
				INFOPLIST_FILE = FightHR/Info.plist;
				IPHONEOS_DEPLOYMENT_TARGET = 16.0;
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/Frameworks",
				);
				MARKETING_VERSION = {MARKETING_VERSION};
				PRODUCT_BUNDLE_IDENTIFIER = {BUNDLE_ID};
				PRODUCT_NAME = FightHR;
				SENTRY_DSN = "{SENTRY_DSN}";
				SWIFT_VERSION = 5.0;
				TARGETED_DEVICE_FAMILY = 1;
			}};
			name = {name};
		}};"""

pbx=f"""// !$*UTF8*$!
{{
	archiveVersion = 1;
	classes = {{
	}};
	objectVersion = 56;
	objects = {{

/* Begin PBXBuildFile section */
{bf}
/* End PBXBuildFile section */

/* Begin PBXFileReference section */
{fr}
/* End PBXFileReference section */

/* Begin PBXFrameworksBuildPhase section */
		{FRAMEWORKS_PHASE} /* Frameworks */ = {{
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
				{SENTRY_BUILD} /* SentrySPM in Frameworks */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
		{MAINGROUP} = {{
			isa = PBXGroup;
			children = (
				{SRCGROUP} /* FightHR */,
				{PRODGROUP} /* Products */,
			);
			sourceTree = "<group>";
		}};
		{SRCGROUP} /* FightHR */ = {{
			isa = PBXGroup;
			children = (
				{SOURCESGROUP} /* Sources */,
				{file_refs[ASSET]} /* {ASSET} */,
				{file_refs[INFO]} /* {INFO} */,
			);
			path = FightHR;
			sourceTree = "<group>";
		}};
		{SOURCESGROUP} /* Sources */ = {{
			isa = PBXGroup;
			children = (
{src_children}
			);
			path = Sources;
			sourceTree = "<group>";
		}};
		{PRODGROUP} /* Products */ = {{
			isa = PBXGroup;
			children = (
				{PRODUCT} /* FightHR.app */,
			);
			name = Products;
			sourceTree = "<group>";
		}};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
		{TARGET} /* FightHR */ = {{
			isa = PBXNativeTarget;
			buildConfigurationList = {CFG_LIST_TGT} /* Build configuration list for PBXNativeTarget "FightHR" */;
			buildPhases = (
				{SOURCES_PHASE} /* Sources */,
				{FRAMEWORKS_PHASE} /* Frameworks */,
				{RES_PHASE} /* Resources */,
			);
			buildRules = (
			);
			dependencies = (
			);
			name = FightHR;
			packageProductDependencies = (
				{SENTRY_PRODUCT} /* SentrySPM */,
			);
			productName = FightHR;
			productReference = {PRODUCT} /* FightHR.app */;
			productType = "com.apple.product-type.application";
		}};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
		{PROJECT} /* Project object */ = {{
			isa = PBXProject;
			attributes = {{
				BuildIndependentTargetsInParallel = 1;
				LastSwiftUpdateCheck = 1500;
				LastUpgradeCheck = 1500;
				TargetAttributes = {{
					{TARGET} = {{
						CreatedOnToolsVersion = 15.0;
					}};
				}};
			}};
			buildConfigurationList = {CFG_LIST_PROJ} /* Build configuration list for PBXProject "FightHR" */;
			compatibilityVersion = "Xcode 14.0";
			developmentRegion = en;
			hasScannedForEncodings = 0;
			knownRegions = (
				en,
				Base,
			);
			mainGroup = {MAINGROUP};
			packageReferences = (
				{SENTRY_PACKAGE} /* XCRemoteSwiftPackageReference "sentry-cocoa" */,
			);
			productRefGroup = {PRODGROUP} /* Products */;
			projectDirPath = "";
			projectRoot = "";
			targets = (
				{TARGET} /* FightHR */,
			);
		}};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
		{RES_PHASE} /* Resources */ = {{
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
				{build_files[ASSET]} /* {ASSET} in Resources */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXResourcesBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
		{SOURCES_PHASE} /* Sources */ = {{
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
{phase_files}
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXSourcesBuildPhase section */

/* Begin XCRemoteSwiftPackageReference section */
		{SENTRY_PACKAGE} /* XCRemoteSwiftPackageReference "sentry-cocoa" */ = {{
			isa = XCRemoteSwiftPackageReference;
			repositoryURL = "https://github.com/getsentry/sentry-cocoa.git";
			requirement = {{
				kind = upToNextMajorVersion;
				minimumVersion = {SENTRY_VERSION};
			}};
		}};
/* End XCRemoteSwiftPackageReference section */

/* Begin XCSwiftPackageProductDependency section */
		{SENTRY_PRODUCT} /* SentrySPM */ = {{
			isa = XCSwiftPackageProductDependency;
			package = {SENTRY_PACKAGE} /* XCRemoteSwiftPackageReference "sentry-cocoa" */;
			productName = SentrySPM;
		}};
/* End XCSwiftPackageProductDependency section */

/* Begin XCBuildConfiguration section */
		{CFG_PROJ_DEBUG} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ENABLE_MODULES = YES;
				CLANG_ENABLE_OBJC_ARC = YES;
				COPY_PHASE_STRIP = NO;
				DEBUG_INFORMATION_FORMAT = dwarf;
				ENABLE_TESTABILITY = YES;
				GCC_OPTIMIZATION_LEVEL = 0;
				GCC_PREPROCESSOR_DEFINITIONS = (
					"DEBUG=1",
					"$(inherited)",
				);
				IPHONEOS_DEPLOYMENT_TARGET = 16.0;
				MTL_ENABLE_DEBUG_INFO = INCLUDE_SOURCE;
				ONLY_ACTIVE_ARCH = YES;
				SDKROOT = iphoneos;
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;
				SWIFT_OPTIMIZATION_LEVEL = "-Onone";
			}};
			name = Debug;
		}};
		{CFG_PROJ_REL} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ENABLE_MODULES = YES;
				CLANG_ENABLE_OBJC_ARC = YES;
				COPY_PHASE_STRIP = NO;
				ENABLE_NS_ASSERTIONS = NO;
				IPHONEOS_DEPLOYMENT_TARGET = 16.0;
				MTL_ENABLE_DEBUG_INFO = NO;
				SDKROOT = iphoneos;
				SWIFT_COMPILATION_MODE = wholemodule;
				SWIFT_OPTIMIZATION_LEVEL = "-O";
				VALIDATE_PRODUCT = YES;
			}};
			name = Release;
		}};
{tgt_cfg(CFG_TGT_DEBUG, "Debug")}
{tgt_cfg(CFG_TGT_REL, "Release")}
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
		{CFG_LIST_PROJ} /* Build configuration list for PBXProject "FightHR" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{CFG_PROJ_DEBUG} /* Debug */,
				{CFG_PROJ_REL} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
		{CFG_LIST_TGT} /* Build configuration list for PBXNativeTarget "FightHR" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{CFG_TGT_DEBUG} /* Debug */,
				{CFG_TGT_REL} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
/* End XCConfigurationList section */
	}};
	rootObject = {PROJECT} /* Project object */;
}}
"""
open("FightHR.xcodeproj/project.pbxproj","w").write(pbx)
print(f"regenerated with {len(SOURCES)} swift files, team {DEVELOPMENT_TEAM}")
