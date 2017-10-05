//
//  main.mm
//  ResourceConverter
//
//  Copyright © 2016-2017 vit9696. All rights reserved.
//

//This file is a shameful terribly written copy-paste-like draft with minimal error checking if at all
//TODO: Rewrite this completely

#import <Foundation/Foundation.h>
#import <Cocoa/Cocoa.h>
#include <initializer_list>
#include <unordered_map>
#include <vector>

#define SYSLOG(str, ...) printf("ResourceConverter: " str "\n", ## __VA_ARGS__)
#define ERROR(str, ...) do { SYSLOG(str, ## __VA_ARGS__); exit(1); } while(0)
NSString *ResourceHeader {@"\
//                                                   \n\
//  kern_resources.cpp                               \n\
//  AppleALC                                         \n\
//                                                   \n\
//  Copyright © 2016-2017 vit9696. All rights reserved.   \n\
//                                                   \n\
//  This is an autogenerated file!                   \n\
//  Please avoid any modifications!                  \n\
//                                                   \n\n\
#include \"kern_resources.hpp\"                      \n\n"
};

static void appendFile(NSString *file, NSString *data) {
	NSFileHandle *handle = [NSFileHandle fileHandleForUpdatingAtPath:file];
	[handle seekToEndOfFile];
	[handle writeData:[data dataUsingEncoding:NSUTF8StringEncoding]];
	[handle closeFile];
}

static NSString *makeStringList(NSString *name, size_t index, NSArray *array, NSString *type=@"char *") {
	auto str = [[NSMutableString alloc] initWithFormat:@"static const %@ %@%zu[] { ", type, name, index];
	
	if ([type isEqualToString:@"char *"]) {
		for (NSString *item in array) {
			[str appendFormat:@"\"%@\", ", item];
		}
	} else {
		for (NSNumber *item in array) {
			[str appendFormat:@"0x%lX, ", [item unsignedLongValue]];
		}
	}
	
	[str appendString:@"};\n"];
	
	return str;
}

static NSDictionary * generateKexts(NSString *file, NSDictionary *kexts) {
	auto kextPathsSection = [[[NSMutableString alloc] initWithUTF8String:"\n// Kext section\n\n"] autorelease];
	auto kextSection = [[[NSMutableString alloc] init] autorelease];
	auto kextNums = [[[NSMutableDictionary alloc] init] autorelease];
	
	[kextSection appendString:@"KernelPatcher::KextInfo ADDPR(kextList)[] {\n"];
	
	size_t kextIndex {0};
	
	for (NSString *kextName in kexts) {
		NSDictionary *kextInfo = [kexts objectForKey:kextName];
		NSString *kextID = [kextInfo objectForKey:@"Id"];
		NSArray *kextPaths = [kextInfo objectForKey:@"Paths"];
		
		[kextPathsSection appendString:makeStringList(@"kextPath", kextIndex, kextPaths)];
		
		[kextSection appendFormat:@"\t{ \"%@\", kextPath%zu, %lu, {false, %s}, {%s}, KernelPatcher::KextInfo::Unloaded },\n",
			kextID, kextIndex, [kextPaths count], [kextInfo objectForKey:@"Reloadable"] ? "true" : "false", [kextInfo objectForKey:@"Detect"] ? "true" : ""];
		
		[kextNums setObject:[NSNumber numberWithUnsignedLongLong:kextIndex] forKey:kextName];
		
		kextIndex++;
	}
	
	[kextSection appendString:@"};\n"];
	[kextSection appendFormat:@"\nconst size_t ADDPR(kextListSize) {%lu};\n", [kexts count]];

	appendFile(file, kextPathsSection);
	appendFile(file, kextSection);

	return kextNums;
}

static NSString *generateFile(NSString *file, NSString *path, NSString *inFile) {
	static size_t fileIndex {0};
	static NSMutableDictionary *fileList = [[[NSMutableDictionary alloc] init] autorelease];
	
	auto fullInPath = [[NSString alloc] initWithFormat:@"%@/%@", path, inFile];
	auto data = [[NSFileManager defaultManager] contentsAtPath:fullInPath];
	auto bytes = static_cast<const uint8_t *>([data bytes]);
	
	if ([fileList objectForKey:fullInPath]) {
		return [[[NSString alloc] initWithFormat:@"file%@, %zu", [fileList objectForKey:fullInPath], [data length]] autorelease];
	}
	
	if (data) {
		appendFile(file, [[[NSString alloc] initWithFormat:@"static const uint8_t file%zu[] {\n", fileIndex] autorelease]);
		
		size_t i = 0;
		while (i < [data length]) {
			auto outLine = [[[NSMutableString alloc] initWithString:@"\t"] autorelease];
			for (size_t p = 0; p < 24 && i < [data length]; p++, i++) {
				[outLine appendFormat:@"0x%0.2X, ", bytes[i]];
			}
			[outLine appendString:@"\n"];
			appendFile(file, outLine);
		}
		
		appendFile(file, [[[NSString alloc] initWithFormat:@"};\n"] autorelease]);
		[fileList setValue:[NSNumber numberWithUnsignedLongLong:fileIndex] forKey:fullInPath];
		fileIndex++;
		return [[[NSString alloc] initWithFormat:@"file%zu, %zu", fileIndex-1, [data length]] autorelease];
	}
	
	return @"nullptr, 0";
}

static NSString *generateRevisions(NSString *file, NSDictionary *codecDict) {
	static size_t revisionIndex {0};
	
	NSArray *revs = [codecDict objectForKey:@"Revisions"];
	
	if (revs) {
		appendFile(file, makeStringList(@"revisions", revisionIndex, revs, @"uint32_t"));
		revisionIndex++;
		return [[[NSString alloc] initWithFormat:@"revisions%zu, %lu", revisionIndex-1, [revs count]] autorelease];
	}
	
	return @"nullptr, 0";
}

static NSString *generatePlatforms(NSString *file, NSDictionary *codecDict, NSString *path) {
	static size_t platformIndex {0};
	
	NSArray *plats = [[codecDict objectForKey:@"Files"] objectForKey:@"Platforms"];
	
	if (plats) {
		auto pStr = [[[NSMutableString alloc] initWithFormat:@"static const CodecModInfo::File platforms%zu[] {\n", platformIndex] autorelease];
		for (NSDictionary *p in plats) {
			[pStr appendFormat:@"\t{ %@, %@, %@, %@},\n",
			 generateFile(file, path, [p objectForKey:@"Path"]),
			 [p objectForKey:@"MinKernel"] ?: @"KernelPatcher::KernelAny",
			 [p objectForKey:@"MaxKernel"] ?: @"KernelPatcher::KernelAny",
			 [p objectForKey:@"Id"]
			];
		}
		[pStr appendString:@"};\n"];
	
		appendFile(file, pStr);
		platformIndex++;
		return [[[NSString alloc] initWithFormat:@"platforms%zu, %lu", platformIndex-1, [plats count]] autorelease];
	}
	
	return @"nullptr, 0";
}

static NSString *generateLayouts(NSString *file, NSDictionary *codecDict, NSString *path) {
	static size_t layoutIndex {0};
	
	NSArray *lts = [[codecDict objectForKey:@"Files"] objectForKey:@"Layouts"];
	
	if (lts) {
		auto pStr = [[[NSMutableString alloc] initWithFormat:@"static const CodecModInfo::File layouts%zu[] {\n", layoutIndex] autorelease];
		for (NSDictionary *p in lts) {
			[pStr appendFormat:@"\t{ %@, %@, %@, %@ },\n",
			 generateFile(file, path, [p objectForKey:@"Path"]),
			 [p objectForKey:@"MinKernel"] ?: @"KernelPatcher::KernelAny",
			 [p objectForKey:@"MaxKernel"] ?: @"KernelPatcher::KernelAny",
			 [p objectForKey:@"Id"]
			 ];
		}
		[pStr appendString:@"};\n"];
		
		appendFile(file, pStr);
		layoutIndex++;
		return [[[NSString alloc] initWithFormat:@"layouts%zu, %lu", layoutIndex-1, [lts count]] autorelease];
	}
	
	return @"nullptr, 0";
}

namespace std {
	template <>
	struct hash<std::vector<uint8_t>> {
		size_t operator()(const std::vector<uint8_t> &x) const {
			auto size = x.size();
			return size ^ (size > 0 ? x[0] : 0xFF);
		}
	};
};

static std::unordered_map<std::vector<uint8_t>, size_t> patchBufMap;

static bool lookupPatchBufIndex(const uint8_t *patch, size_t len, size_t &index) {
	std::vector<uint8_t> k;
	k.assign(patch, patch+len);
	auto it = patchBufMap.find(k);
	if (it != patchBufMap.end()) {
		index = it->second;
		return true;
	}
	return false;
}

static void storePatchBufIndex(const uint8_t *patch, size_t len, size_t index) {
	std::vector<uint8_t> k;
	k.assign(patch, patch+len);
	patchBufMap[k] = index;
}

static NSString *generatePatches(NSString *file, NSArray *patches, NSDictionary *kextIndexes, long *num=nullptr, NSString *header=nullptr) {
	static size_t patchIndex {0};
	static size_t patchBufIndex {0};

	if (patches) {
		auto pStr = [NSMutableString alloc];
		pStr = header ? [[pStr initWithString:header] autorelease] : [[pStr initWithFormat:@"static const KextPatch patches%zu[] {\n", patchIndex] autorelease];
		auto pbStr = [[[NSMutableString alloc] init] autorelease];
		for (NSDictionary *p in patches) {
			const size_t PatchNum = 2;
            NSData *f[PatchNum] = {[p objectForKey:@"Find"], [p objectForKey:@"Replace"]};
			size_t patchBufIndexes[PatchNum] {};
			
			if ([f[0] length] != [f[1] length]) {
				[pStr appendString:@"#error not matching patch lengths\n"];
				continue;
			}
			
			for (size_t i = 0; i < PatchNum; i++) {
				auto patchBuf = reinterpret_cast<const uint8_t *>([f[i] bytes]);
				size_t patchLen = [f[i] length];
				
				if (!lookupPatchBufIndex(patchBuf, patchLen, patchBufIndexes[i])) {
					[pbStr appendString:[[[NSString alloc] initWithFormat:@"static const uint8_t patchBuf%zu[] { ", patchBufIndex] autorelease]];
					
					for (size_t b = 0; b < patchLen; b++) {
						[pbStr appendString:[[[NSString alloc] initWithFormat:@"0x%0.2X, ", patchBuf[b]] autorelease]];
					}
					
					[pbStr appendString:@"};\n"];
					
					patchBufIndexes[i] = patchBufIndex++;
					storePatchBufIndex(patchBuf, patchLen, patchBufIndexes[i]);
				}
			}
			
			[pStr appendFormat:@"\t{ { &ADDPR(kextList)[%@], patchBuf%zu, patchBuf%zu, %zu, %@ }, %@, %@ },\n",
			 [kextIndexes objectForKey:[p objectForKey:@"Name"]],
			 patchBufIndexes[0],
			 patchBufIndexes[1],
			 [f[0] length],
			 [p objectForKey:@"Count"] ?: @"0",
			 [p objectForKey:@"MinKernel"] ?: @"KernelPatcher::KernelAny",
			 [p objectForKey:@"MaxKernel"] ?: @"KernelPatcher::KernelAny"
			];
		}
		[pStr appendString:@"};\n"];
		if (num)
			*num = [patches count];
		
		appendFile(file, pbStr);
		appendFile(file, pStr);
		patchIndex++;
		return [[[NSString alloc] initWithFormat:@"patches%zu, %lu", patchIndex-1, [patches count]] autorelease];
	}
	
	return @"nullptr, 0";
}

static size_t generateCodecs(NSString *file, NSString *vendor, NSString *path, NSDictionary *kextIndexes) {
	appendFile(file, [[[NSString alloc] initWithFormat:@"\n// %@ CodecMod section\n\n", vendor] autorelease]);

	auto codecModSection = [[[NSMutableString alloc] initWithFormat:@"static CodecModInfo codecMod%@[] {\n", vendor] autorelease];
	auto fm = [NSFileManager defaultManager];
	NSArray *entries = [fm contentsOfDirectoryAtPath:path error:nil];
	
	size_t codecs {0};
	for (NSString *entry in entries) {
		NSString *baseDirStr = [[[NSString alloc] initWithFormat:@"%@/%@", path, entry] autorelease];
		NSString *infoCfgStr = [[[NSString alloc] initWithFormat:@"%@/Info.plist", baseDirStr] autorelease];
		
		// Dir exists and is codec dir
		if ([fm fileExistsAtPath:infoCfgStr]) {
			auto codecDict = [NSDictionary dictionaryWithContentsOfFile:infoCfgStr];
			// Vendor match
			if ([[codecDict objectForKey:@"Vendor"] isEqualToString:vendor]) {
				auto revs = generateRevisions(file, codecDict);
				auto platforms = generatePlatforms(file, codecDict, baseDirStr);
				auto layouts = generateLayouts(file, codecDict, baseDirStr);
				auto patches = generatePatches(file, [codecDict objectForKey:@"Patches"], kextIndexes);
			
				[codecModSection appendFormat:@"\t{ \"%@\", 0x%X, %@, %@, %@, %@ },\n",
				 [codecDict objectForKey:@"CodecName"],
				 [[codecDict objectForKey:@"CodecID"] unsignedShortValue],
				 revs, platforms, layouts, patches
				];
				codecs++;
			}
		}
	}
	
	[codecModSection appendString:@"};\n"];
	appendFile(file, codecModSection);
	
	return codecs;
}

static void generateControllers(NSString *file, NSArray *ctrls, NSDictionary *vendors, NSDictionary *kextIndexes) {
	appendFile(file, @"\n// ControllerMod section\n\n");
	
	auto ctrlModSection = [[[NSMutableString alloc] initWithString:@"ControllerModInfo ADDPR(controllerMod)[] {\n"] autorelease];

	for (NSDictionary *entry in ctrls) {
		auto revs = generateRevisions(file, entry);
		auto patches = generatePatches(file, [entry objectForKey:@"Patches"], kextIndexes);
		
		auto model = @"WIOKit::ComputerModel::ComputerAny";
		if ([entry objectForKey:@"Model"]) {
			if ([[entry objectForKey:@"Model"] isEqualToString:@"Laptop"]) {
				model = @"WIOKit::ComputerModel::ComputerLaptop";
			} else if ([[entry objectForKey:@"Model"] isEqualToString:@"Desktop"]) {
				model = @"WIOKit::ComputerModel::ComputerDesktop";
			}
		}
				
		[ctrlModSection appendFormat:@"\t{ \"%@\", 0x%X, 0x%X, %@, %@, %@, %@ },\n",
		 [entry objectForKey:@"Name"],
		 [[vendors objectForKey:[entry objectForKey:@"Vendor"]] unsignedShortValue],
		 [[entry objectForKey:@"Device"] unsignedShortValue],
		 revs, [entry objectForKey:@"Platform"] ?: @"ControllerModInfo::PlatformAny",
		 model, patches
		];
	}
	
	[ctrlModSection appendString:@"};\n"];
	[ctrlModSection appendFormat:@"\nconst size_t ADDPR(controllerModSize) {%lu};\n", [ctrls count]];
	appendFile(file, ctrlModSection);
}

/*static void generateUserPatches(NSString *file, NSArray *userp, NSDictionary *kextIndexes) {
	appendFile(file, @"\n// UserPatches section\n\n");
	
	long count;
	generatePatches(file, userp, kextIndexes, &count, @"KextPatch userPatch[] {\n");
	appendFile(file, [[[NSMutableString alloc] initWithFormat:@"\nconst size_t userPatchSize {%lu};\n", count] autorelease]);
}*/

static void generateVendors(NSString *file, NSDictionary *vendors, NSString *path, NSDictionary *kextIndexes) {
	auto vendorSection = [[[NSMutableString alloc] initWithUTF8String:"\n// Vendor section\n\n"] autorelease];
	
	[vendorSection appendString:@"VendorModInfo ADDPR(vendorMod)[] {\n"];
	
	for (NSString *dictKey in vendors) {
		NSNumber *vendorID = [vendors objectForKey:dictKey];
		size_t num = generateCodecs(file, dictKey, path, kextIndexes);
		[vendorSection appendFormat:@"\t{ \"%@\", 0x%X, codecMod%@, %zu },\n",
			dictKey, [vendorID unsignedShortValue], dictKey, num];
	}
	
	[vendorSection appendString:@"};\n"];
	[vendorSection appendFormat:@"\nconst size_t ADDPR(vendorModSize) {%lu};\n", [vendors count]];
	appendFile(file, vendorSection);
}

static void generateLookup(NSString *file, NSArray *lookup) {
	appendFile(file, @"\n// Lookup section\n\n");

	auto trees = [[[NSMutableString alloc] init] autorelease];
	auto lookups = [[[NSMutableString alloc] init] autorelease];
	size_t treeIndex {0};
	
	for (NSDictionary *set in lookup) {
		// Build tree
		NSArray *treeArr = [set objectForKey:@"Tree"];
		[trees appendString:makeStringList(@"tree", treeIndex, treeArr)];
		
		// Build lookup
		[lookups appendFormat:@"\t{ tree%zu, %lu, %@, %@ },\n",
			treeIndex, [treeArr count],
			[set objectForKey:@"controllerNum"],
			[set objectForKey:@"Detect"] ? @"true" : @"false"];
		
		treeIndex++;
	}
	appendFile(file, trees);
	appendFile(file, @"CodecLookupInfo ADDPR(codecLookup)[] {\n");
	appendFile(file, lookups);
	appendFile(file, @"};\n");
	appendFile(file, [[[NSString alloc] initWithFormat:@"const size_t ADDPR(codecLookupSize) {%zu};\n", treeIndex] autorelease]);
}

int main(int argc, const char * argv[]) {
	@autoreleasepool {
		if (argc != 3)
			ERROR("Invalid usage");
		
		auto basePath = [[[NSString alloc] initWithUTF8String:argv[1]] autorelease];
		auto lookupCfg = [[[NSString alloc] initWithFormat:@"%@/CodecLookup.plist", basePath] autorelease];
		auto vendorsCfg = [[[NSString alloc] initWithFormat:@"%@/Vendors.plist", basePath] autorelease];
		auto kextsCfg = [[[NSString alloc] initWithFormat:@"%@/Kexts.plist",basePath] autorelease];
		auto ctrlsCfg = [[[NSString alloc] initWithFormat:@"%@/Controllers.plist",basePath] autorelease];
		//auto userCfg = [[[NSString alloc] initWithFormat:@"%@/UserPatches.plist",basePath] autorelease];
		auto outputCpp = [[[NSString alloc] initWithUTF8String:argv[2]] autorelease];
		
		auto lookup = [NSArray arrayWithContentsOfFile:lookupCfg];
		auto vendors = [NSDictionary dictionaryWithContentsOfFile:vendorsCfg];
		auto kexts = [NSDictionary dictionaryWithContentsOfFile:kextsCfg];
		auto ctrls = [NSArray arrayWithContentsOfFile:ctrlsCfg];
		//auto userp = [NSArray arrayWithContentsOfFile:userCfg];
		
		if (!lookup || !vendors || !kexts || !ctrls)
			ERROR("Missing resource data (lookup:%p, vendors:%p, kexts:%p, ctrls:%p)", lookup, vendors, kexts, ctrls);
		
		// Create a file
		[[NSFileManager defaultManager] createFileAtPath:outputCpp contents:nil attributes:nil];
		
		appendFile(outputCpp, ResourceHeader);
		generateLookup(outputCpp, lookup);
		auto kextIndexes = generateKexts(outputCpp, kexts);
		generateVendors(outputCpp, vendors, basePath, kextIndexes);
		generateControllers(outputCpp, ctrls, vendors, kextIndexes);
		//generateUserPatches(outputCpp, userp, kextIndexes);
	}
}
