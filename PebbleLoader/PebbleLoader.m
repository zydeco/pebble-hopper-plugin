//
//  PebbleLoader.m
//  PebbleLoader
//
//  Created by Jesús A. Álvarez on 06/11/2018.
//  Copyright © 2018 namedfork. All rights reserved.
//

#import "PebbleLoader.h"
#import <Hopper/HPTypeDesc.h>
#import <Hopper/HPMethodSignature.h>
#import "PBWLoader.h"

#define kTrampolineFunctionName @"jump_to_pbl_function"

@interface PebbleLoader (Types)

- (void)registerDataTypes:(NSObject<HPDisassembledFile>*)file;
- (NSObject<HPTypeDesc>*)typeFromString:(NSString*)typeName inFile:(NSObject<HPDisassembledFile>*)file;

@end

@implementation PebbleLoader
{
    NSObject<HPHopperServices> *_services;
    NSArray<NSString*> *pebbleAPI;
}

+ (int)sdkVersion {
    return HOPPER_CURRENT_SDK_VERSION;
}

- (instancetype)initWithHopperServices:(NSObject<HPHopperServices> *)services {
    if (self = [super init]) {
        _services = services;
        NSBundle *bundle = [NSBundle bundleForClass:[self class]];
        NSString *apiFilePath = [bundle pathForResource:@"api" ofType:@"txt"];
        pebbleAPI = [[NSString stringWithContentsOfFile:apiFilePath encoding:NSASCIIStringEncoding error:NULL] componentsSeparatedByString:@"\n"];
    }
    return self;
}

- (nonnull NSObject<HPHopperUUID> *)pluginUUID {
    return [_services UUIDWithString:@"6bccbe4a-f1de-4309-84c4-3a47155c1392"];
}

- (HopperPluginType)pluginType {
    return Plugin_Loader;
}

- (NSString *)pluginName {
    return @"Pebble Binary";
}

- (NSString *)pluginDescription {
    return @"Pebble Binary File Loader";
}

- (NSString *)pluginAuthor {
    return @"Jesús A. Álvarez";
}

- (NSString *)pluginCopyright {
    return @"©2018 namedfork.net";
}

- (NSString *)pluginVersion {
    return @"1.0.0";
}

- (NSArray<NSString *> *)commandLineIdentifiers {
    return @[@"Pebble"];
}

- (BOOL)canLoadDebugFiles {
    return NO;
}

- (BOOL)hasPebbleHeader:(NSData*)data {
    return data.length > 0x84 && memcmp(data.bytes, "PBLAPP\0\0", 8) == 0;
}

- (BOOL)isPBW:(NSData*)data pathsMap:(NSDictionary<NSString*,NSString*>**)outPathsMap {
    PBWLoader *pbwLoader = [[PBWLoader alloc] initWithData:data];
    if (pbwLoader == nil) {
        NSLog(@"%@: Could not initialize PBWLoader", self.className);
        return NO;
    }
    NSData *appInfoData = [pbwLoader readFile:@"appinfo.json"];
    if (appInfoData == nil) {
        NSLog(@"%@: Could not find appinfo.json in archive", self.className);
        return NO;
    }
    
    NSDictionary *appInfo = [NSJSONSerialization JSONObjectWithData:appInfoData options:0 error:NULL];
    if (appInfo == nil) {
        NSLog(@"%@: Could not deserialize app info", self.className);
        return NO;
    }
    NSArray<NSString*> *targetPlatforms = appInfo[@"targetPlatforms"];
    if (targetPlatforms == nil) {
        if (outPathsMap) {
            *outPathsMap = @{@"aplite (pebble-app.bin)": @"pebble-app.bin"};
        }
        return YES;
    }
    NSMutableDictionary *pathsMap = [NSMutableDictionary dictionaryWithCapacity:4];
    for (NSString *platform in targetPlatforms) {
        if ([platform isEqualToString:@"aplite"] && [pbwLoader hasFile:@"pebble-app.bin"]) {
            pathsMap[@"aplite (pebble-app.bin)"] = @"pebble-app.bin";
        } else {
            NSString *platformBinPath = [NSString stringWithFormat:@"%@/pebble-app.bin", platform];
            pathsMap[[NSString stringWithFormat:@"%@ (%@)", platform, platformBinPath]] = platformBinPath;
        }
    }
    
    if (outPathsMap) {
        *outPathsMap = pathsMap.copy;
    }
    return YES;
}

- (NSArray<NSObject<HPDetectedFileType> *> *)detectedTypesForData:(NSData *)data ofFileNamed:(NSString*)fileName {
    NSDictionary<NSString*,NSString*> *pathsMap = nil;
    if ([self hasPebbleHeader:data]) {
        NSObject<HPDetectedFileType> *type = [_services detectedType];
        type.fileDescription = @"Pebble App";
        type.addressWidth = AW_32bits;
        type.cpuFamily = @"arm";
        type.cpuSubFamily = @"v6";
        type.shortDescriptionString = @"pebble_app";
        return @[type];
    } else if ([fileName.pathExtension isEqualToString:@"pbw"] && [self isPBW:data pathsMap:&pathsMap]) {
        NSObject<HPDetectedFileType> *type = [_services detectedType];
        type.fileDescription = @"Pebble Bundle";
        type.addressWidth = AW_32bits;
        type.cpuFamily = @"arm";
        type.cpuSubFamily = @"v6";
        type.shortDescriptionString = @"pebble_bundle";
        type.compositeFile = YES;
        
        NSObject<HPLoaderOptionComponents> *options;
        NSArray *sortedPlatforms = [pathsMap.allKeys sortedArrayUsingSelector:@selector(compare:)];
        options = [_services stringListComponentWithLabel:@"Platform" andList:sortedPlatforms];
        type.additionalParameters = @[options];
        type.internalObject = @[fileName, pathsMap];
        
        return @[type];
    }
    return @[];
}

- (NSData *)extractFromData:(NSData *)data usingDetectedFileType:(NSObject<HPDetectedFileType> *)fileType returnAdjustOffset:(uint64_t *)adjustOffset returnAdjustFilename:(NSString **)filename {
    PBWLoader *loader = [[PBWLoader alloc] initWithData:data];
    if (loader) {
        NSObject<HPLoaderOptionComponents> *stringListComponent = fileType.additionalParameters[0];
        NSString *originalFileName = fileType.internalObject[0];
        NSDictionary<NSString*,NSString*> *pathsMap = fileType.internalObject[1];
        
        NSString *name = stringListComponent.stringList[stringListComponent.selectedStringIndex];
        NSString *path = pathsMap[name];
        NSString *platformName = [name componentsSeparatedByString:@" "][0];
        
        if (filename) {
            if (pathsMap.count == 1) {
                *filename = originalFileName;
            } else {
                *filename = [NSString stringWithFormat:@"%@-%@", originalFileName.stringByDeletingPathExtension, platformName];
            }
        }
        return [loader readFile:path];
    }
    return nil;
}

- (void)fixupRebasedFile:(NSObject<HPDisassembledFile> *)file withSlide:(int64_t)slide originalFileData:(NSData *)fileData {
    // TODO: reapply relocation table
    NSLog(@"TODO: relocate %lld from %llx", slide, file.fileBaseAddress);
}

- (FileLoaderLoadingStatus)loadDebugData:(NSData *)data forFile:(NSObject<HPDisassembledFile> *)file usingCallback:(FileLoadingCallbackInfo)callback {
    return DIS_NotSupported;
}

- (NSData*)applyRelocationToBinary:(NSData*)binary withLoadAddress:(uint32_t)baseAddress {
    uint8_t *data = malloc(binary.length);
    memcpy(data, binary.bytes, binary.length);
    uint8_t headerMajorVersion = data[0x08];
    uint32_t relocTableOffset;
    uint32_t numRelocEntries;
    if (headerMajorVersion < 9) {
        relocTableOffset = OSReadLittleInt32(data, 0x64);
        numRelocEntries = OSReadLittleInt32(data, 0x68);
    } else {
        relocTableOffset = OSReadLittleInt16(data, 0x0e);
        numRelocEntries = OSReadLittleInt32(data, 0x64);
    }
    for (int i=0; i < numRelocEntries; i++) {
        uint32_t relocOffset = OSReadLittleInt32(data, relocTableOffset + (4*i));
        uint32_t relocValue = OSReadLittleInt32(data, relocOffset);
        OSWriteLittleInt32(data, relocOffset, relocValue + baseAddress);
    }
    return [NSData dataWithBytesNoCopy:data length:binary.length freeWhenDone:YES];
}

- (FileLoaderLoadingStatus)loadData:(NSData *)loadData usingDetectedFileType:(NSObject<HPDetectedFileType> *)fileType options:(FileLoaderOptions)options forFile:(NSObject<HPDisassembledFile> *)file usingCallback:(FileLoadingCallbackInfo)callback {
    if (![self hasPebbleHeader:loadData]) {
        return DIS_BadFormat;
    }
    
    // map file into memory
    uint32_t baseAddress = 0x10000;
    NSData *data = [self applyRelocationToBinary:loadData withLoadAddress:baseAddress];
    const uint8_t *header = data.bytes;
    uint8_t headerMajorVersion = header[0x08];
    uint32_t loadSize = OSReadLittleInt16(header, 0x0e);
    uint32_t virtualSize = (headerMajorVersion >= 0x10) ? OSReadLittleInt16(header, 0x80) : OSReadLittleInt32(header, 0x64);
    NSObject<HPSegment> *segment = [file addSegmentAt:baseAddress size:virtualSize];
    segment.mappedData = data;
    segment.segmentName = @"app";
    segment.readable = YES;
    segment.writable = YES;
    segment.executable = YES;
    
    // header section
    NSObject<HPSection> *headerSection = [segment addSectionAt:baseAddress size:0x84];
    headerSection.sectionName = @"header";
    headerSection.pureDataSection = YES;
    headerSection.fileOffset = 0;
    headerSection.fileLength = 0x84;
    headerSection.pureDataSection = YES;
    
    Address nextAddress = baseAddress;
    [file setName:@".pblapp" forVirtualAddress:nextAddress reason:NCReason_Import];
    [file setType:Type_ASCII atVirtualAddress:nextAddress forLength:8];
    [file setInlineComment:@"magic" atVirtualAddress:nextAddress reason:CCReason_Automatic];
    nextAddress += 8;
    
    [file setType:Type_Int8 atVirtualAddress:nextAddress forLength:2];
    struct {
        uint8_t major, minor;
    } headerVersion = {
        .major = header[0x08],
        .minor = header[0x09]
    };
    [file setInlineComment:[NSString stringWithFormat:@"struct_version = %d.%d", headerVersion.major, headerVersion.minor] atVirtualAddress:nextAddress reason:CCReason_Automatic];
    nextAddress += 2;
    
    [file setType:Type_Int8 atVirtualAddress:nextAddress forLength:2];
    [file setInlineComment:[NSString stringWithFormat:@"sdk_version = %d.%d", header[0x0a], header[0x0b]] atVirtualAddress:nextAddress reason:CCReason_Automatic];
    nextAddress += 2;
    
    [file setType:Type_Int8 atVirtualAddress:nextAddress forLength:2];
    [file setInlineComment:[NSString stringWithFormat:@"app_version = %d.%d", header[0x0c], header[0x0d]] atVirtualAddress:nextAddress reason:CCReason_Automatic];
    nextAddress += 2;
    
    [file setType:Type_Int16 atVirtualAddress:nextAddress forLength:2];
    [file setInlineComment:@"load_size" atVirtualAddress:nextAddress reason:CCReason_Automatic];
    nextAddress += 2;
    
    [file setType:Type_Int32 atVirtualAddress:nextAddress forLength:4];
    [file setInlineComment:@"offset" atVirtualAddress:nextAddress reason:CCReason_Automatic];
    nextAddress += 4;
    
    [file setType:Type_Int32 atVirtualAddress:nextAddress forLength:4];
    [file setInlineComment:@"crc" atVirtualAddress:nextAddress reason:CCReason_Automatic];
    nextAddress += 4;

    [file setType:Type_ASCII atVirtualAddress:nextAddress forLength:32];
    [file setInlineComment:@"name" atVirtualAddress:nextAddress reason:CCReason_Automatic];
    nextAddress += 32;
    
    [file setType:Type_ASCII atVirtualAddress:nextAddress forLength:32];
    [file setInlineComment:@"company" atVirtualAddress:nextAddress reason:CCReason_Automatic];
    nextAddress += 32;
    
    [file setType:Type_Int32 atVirtualAddress:nextAddress forLength:4];
    [file setInlineComment:@"icon_resource_id" atVirtualAddress:nextAddress reason:CCReason_Automatic];
    nextAddress += 4;

    [file setType:Type_Int32 atVirtualAddress:nextAddress forLength:4];
    [file setInlineComment:@"jump_table_addr" atVirtualAddress:nextAddress reason:CCReason_Automatic];
    nextAddress += 4;
    
    [file setType:Type_Int32 atVirtualAddress:nextAddress forLength:4];
    [file setInlineComment:@"flags" atVirtualAddress:nextAddress reason:CCReason_Automatic];
    nextAddress += 4;

    // .major:0x09 .minor:0x00 -- 2.0, no more reloc_list_start
    if (headerVersion.major < 9) {
        [file setType:Type_Int32 atVirtualAddress:nextAddress forLength:4];
        [file setInlineComment:@"reloc_list_start" atVirtualAddress:nextAddress reason:CCReason_Automatic];
        nextAddress += 4;
    }
    [file setType:Type_Int32 atVirtualAddress:nextAddress forLength:4];
    [file setInlineComment:@"num_reloc_entries" atVirtualAddress:nextAddress reason:CCReason_Automatic];
    nextAddress += 4;
    
    [file setType:Type_Int8 atVirtualAddress:nextAddress forLength:16];
    NSUUID *appUUID = [[NSUUID alloc] initWithUUIDBytes:header+(nextAddress-baseAddress)];
    [file setInlineComment:[NSString stringWithFormat:@"UUID: %@", appUUID] atVirtualAddress:nextAddress reason:CCReason_Automatic];
    nextAddress += 16;
    
    // .major:0x08 .minor:0x02 -- 2.0, added resource crc and resource timestamp
    if (headerVersion.major > 0x08 || (headerVersion.major == 0x08 && headerVersion.minor >= 0x02)) {
        [file setType:Type_Int32 atVirtualAddress:nextAddress forLength:4];
        [file setInlineComment:@"resource_crc" atVirtualAddress:nextAddress reason:CCReason_Automatic];
        nextAddress += 4;
        
        [file setType:Type_Int32 atVirtualAddress:nextAddress forLength:4];
        [file setInlineComment:@"resource_timestamp" atVirtualAddress:nextAddress reason:CCReason_Automatic];
        nextAddress += 4;
    }

    // .major:0x10 .minor:0x00 -- 2.0, added virtual_size
    if (headerVersion.major >= 0x10) {
        [file setType:Type_Int16 atVirtualAddress:nextAddress forLength:2];
        [file setInlineComment:@"virtual_size" atVirtualAddress:nextAddress reason:CCReason_Automatic];
        nextAddress += 2;
    }

    // API trampoline (20 bytes, last 4 are pointed at by jump table addr */
    uint32_t jumpTableOffset = OSReadLittleInt32(header, 0x5c);
    uint32_t trampolineSize = 20;
    uint32_t trampolineOffset = jumpTableOffset + 4 - trampolineSize;
    NSObject<HPSection> *trampolineSection = [segment addSectionAt:baseAddress + trampolineOffset size:trampolineSize];
    trampolineSection.sectionName = @"trampoline";
    trampolineSection.fileOffset = trampolineOffset;
    trampolineSection.fileLength = trampolineSize;
    [file setName:kTrampolineFunctionName forVirtualAddress:baseAddress + trampolineOffset reason:NCReason_Import];
    [file setType:Type_Procedure atVirtualAddress:baseAddress + trampolineOffset forLength: trampolineSize - 4];
    [file addPotentialProcedure:trampolineOffset];
    [file setType:Type_Int32 atVirtualAddress:baseAddress + jumpTableOffset forLength:4];
    
    // text
    uint32_t textOffset = trampolineOffset + trampolineSize;
    uint32_t textSize = loadSize - textOffset;
    NSObject<HPSection> *codeSection = [segment addSectionAt:baseAddress + textOffset size:textSize];
    codeSection.sectionName = @"text";
    codeSection.containsCode = YES;
    codeSection.fileOffset = textOffset;
    codeSection.fileLength = textSize;
    
    // bss
    uint32_t bssSize = virtualSize - loadSize;
    NSObject<HPSection> *bssSection = [segment addSectionAt:baseAddress + textOffset + textSize size:bssSize];
    bssSection.sectionName = @"bss";
    bssSection.zeroFillSection = YES;
    
    file.cpuFamily = @"arm";
    file.cpuSubFamily = @"v6";
    file.addressSpaceWidthInBits = 32;
    file.integerWidthInBits = 32;
    uint32_t entryPoint = baseAddress + OSReadLittleInt32(header, 0x10);
    [file addEntryPoint:entryPoint];
    [file setName:@"main" forVirtualAddress:entryPoint reason:NCReason_Import];
    [self registerDataTypes:file];
    
    [self performSelectorInBackground:@selector(waitForDocument:) withObject:_services.currentDocument];
    return DIS_OK;
}

- (void)waitForDocument:(NSObject<HPDocument>*)document {
    [NSThread sleepForTimeInterval:0.5];
    [document waitForBackgroundProcessToEnd];
    NSObject<HPDisassembledFile> *file = document.disassembledFile;
    NSObject<HPProcedure> *trampoline = [file procedureAt:[file findVirtualAddressNamed:kTrampolineFunctionName]];
    if (trampoline == nil) {
        [self performSelector:_cmd withObject:document afterDelay:0.01];
        return;
    }
    [self mapAPICalls:document];
}

- (void)mapAPICalls:(NSObject<HPDocument>*)document {
    NSObject<HPDisassembledFile> *file = document.disassembledFile;
    NSObject<HPProcedure> *trampoline = [file procedureAt:[file findVirtualAddressNamed:kTrampolineFunctionName]];
    __block BOOL cancel = NO;
    [document beginToWait:@"Mapping API calls…" cancelBlock:^{
        cancel = YES;
    }];
    
    for (NSObject<HPCallReference> *caller in trampoline.allCallers) {
        NSObject<HPProcedure> *proc = [file procedureAt:caller.from];
        
        // tail call optimization might prevent procedure from being detected
        NSObject<HPBasicBlock> *block = [proc basicBlockContainingInstructionAt:caller.from];
        if (block.to - block.from != 4) {
            [file addProblemAt:block.from withString:@"API call candidate block is the wrong size, trying anyway."];
        }
        if (proc.entryPoint != block.from) {
            Address oldProcAddress = proc.entryPoint;
            proc = [file makeProcedureAt:block.from];
            // don't discard the old procedure!
            [file makeProcedureAt:oldProcAddress];
        }
        
        // call index is always word after the function
        Address callIndexAddress = [file findNextAddress:caller.from ofTypeOrMetaType:Type_Data wrapping:NO];
        if (callIndexAddress > caller.from + 4) {
            [file addProblemAt:proc.entryPoint withString:@"Couldn't find API call number"];
        } else {
            NSInteger call = [file readUInt32AtVirtualAddress:callIndexAddress] / 4;
            [self setAPICall:call forProcedure:proc inFile:file];
        }
    }
    [document endWaiting];
    [document performSelectorOnMainThread:@selector(updateUI) withObject:nil waitUntilDone:NO];
}

- (NSObject<HPMethodSignature>*)methodSignatureForAPICall:(NSInteger)call {
    
    return nil;
}

- (void)setAPICall:(NSInteger)call forProcedure:(NSObject<HPProcedure>*)proc inFile:(NSObject<HPDisassembledFile>*)file {
    NSString *name;
    Address address = proc.entryPoint;
    NSString *apiDef = call < pebbleAPI.count ? pebbleAPI[call] : nil;
    if (apiDef) {
        NSArray<NSString*> *words = [apiDef componentsSeparatedByString:@" "];
        if (words.count == 1) {
            name = words[0];
        } else {
            name = words[1];
            NSObject<HPMethodSignature> *signature = proc.signature;
            signature.returnType = [self typeFromString:words[0] inFile:file];
            while(signature.argumentCount > 0) {
                [signature removeArgumentAtIndex:0];
            }
            for (NSInteger i = 2; i < words.count; i++) {
                [signature addArgumentWithType:[self typeFromString:words[i] inFile:file]];
            }
        }
        // FIXME: gcolor_equal__deprecated is gcolor_equal in Aplite
        // FIXME: call 613 and over don't exist in Aplite
    } else {
        // unkonwn call
        name = [NSString stringWithFormat:@"pebble__api_call_%d", (int)call];
        [file setInlineComment:@"unknown API call" atVirtualAddress:address reason:CCReason_Automatic];
        [file addProblemAt:address withString:@"Unknown API call"];
    }
    [file setName:name forVirtualAddress:address reason:NCReason_Import];
}

@end
