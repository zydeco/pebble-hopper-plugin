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

#define HEADER_ADDR 0x0                // 8 bytes
#define STRUCT_VERSION_ADDR 0x8        // 2 bytes
#define SDK_VERSION_ADDR 0xa           // 2 bytes
#define APP_VERSION_ADDR 0xc           // 2 bytes
#define LOAD_SIZE_ADDR 0xe             // 2 bytes
#define OFFSET_ADDR 0x10               // 4 bytes
#define CRC_ADDR 0x14                  // 4 bytes
#define NAME_ADDR 0x18                 // 32 bytes
#define COMPANY_ADDR 0x38              // 32 bytes
#define ICON_RES_ID_ADDR 0x58          // 4 bytes
#define JUMP_TABLE_ADDR 0x5c           // 4 bytes
#define FLAGS_ADDR 0x60                // 4 bytes
#define NUM_RELOC_ENTRIES_ADDR 0x64    // 4 bytes
#define UUID_ADDR 0x68                 // 16 bytes
#define RESOURCE_CRC_ADDR 0x78         // 4 bytes
#define RESOURCE_TIMESTAMP_ADDR 0x7c   // 4 bytes
#define VIRTUAL_SIZE_ADDR 0x80         // 2 bytes
#define HEADER_SIZE 0x82

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

- (HopperUUID *)pluginUUID {
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

- (NSString *)commandLineIdentifier {
    return @"Pebble";
}

- (BOOL)canLoadDebugFiles {
    return NO;
}

- (BOOL)hasPebbleHeader:(NSData*)data {
    return data.length > 0x84 && memcmp(data.bytes, "PBLAPP\0\0", 8) == 0;
}

- (NSArray<NSObject<HPDetectedFileType> *> *)detectedTypesForData:(NSData *)data {
    if ([self hasPebbleHeader:data]) {
        NSObject<HPDetectedFileType> *type = [_services detectedType];
        type.fileDescription = @"Pebble App";
        type.addressWidth = AW_32bits;
        type.cpuFamily = @"arm";
        type.cpuSubFamily = @"v6";
        type.shortDescriptionString = @"pebble_app";
        return @[type];
    }
    return @[];
}

- (NSData *)extractFromData:(NSData *)data usingDetectedFileType:(NSObject<HPDetectedFileType> *)fileType returnAdjustOffset:(uint64_t *)adjustOffset {
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
    uint32_t relocTableOffset = OSReadLittleInt16(data, LOAD_SIZE_ADDR);
    uint32_t numRelocEntries = OSReadLittleInt32(data, NUM_RELOC_ENTRIES_ADDR);
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
    uint32_t loadSize = OSReadLittleInt16(header, LOAD_SIZE_ADDR);
    uint32_t virtualSize = OSReadLittleInt16(header, VIRTUAL_SIZE_ADDR);
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
    [file setName:@".pblapp" forVirtualAddress:baseAddress reason:NCReason_Import];
    [file setType:Type_ASCII atVirtualAddress:baseAddress forLength:8];
    [file setInlineComment:@"magic" atVirtualAddress:baseAddress reason:CCReason_Automatic];
    
    [file setType:Type_Int8 atVirtualAddress:baseAddress + STRUCT_VERSION_ADDR forLength:2];
    [file setInlineComment:[NSString stringWithFormat:@"struct_version = %d.%d", header[STRUCT_VERSION_ADDR], header[STRUCT_VERSION_ADDR+1]] atVirtualAddress:baseAddress + STRUCT_VERSION_ADDR reason:CCReason_Automatic];
    
    [file setType:Type_Int8 atVirtualAddress:baseAddress + SDK_VERSION_ADDR forLength:2];
    [file setInlineComment:[NSString stringWithFormat:@"sdk_version = %d.%d", header[SDK_VERSION_ADDR], header[SDK_VERSION_ADDR+1]] atVirtualAddress:baseAddress + SDK_VERSION_ADDR reason:CCReason_Automatic];
    
    [file setType:Type_Int8 atVirtualAddress:baseAddress + APP_VERSION_ADDR forLength:2];
    [file setInlineComment:[NSString stringWithFormat:@"app_version = %d.%d", header[APP_VERSION_ADDR], header[APP_VERSION_ADDR+1]] atVirtualAddress:baseAddress + APP_VERSION_ADDR reason:CCReason_Automatic];
    
    [file setType:Type_Int16 atVirtualAddress:baseAddress + LOAD_SIZE_ADDR forLength:2];
    [file setInlineComment:@"loadSize" atVirtualAddress:baseAddress + LOAD_SIZE_ADDR reason:CCReason_Automatic];

    [file setType:Type_Int32 atVirtualAddress:baseAddress + OFFSET_ADDR forLength:4];
    [file setInlineComment:@"offset" atVirtualAddress:baseAddress + OFFSET_ADDR reason:CCReason_Automatic];
    
    [file setType:Type_Int32 atVirtualAddress:baseAddress + CRC_ADDR forLength:4];
    [file setInlineComment:@"crc" atVirtualAddress:baseAddress + CRC_ADDR reason:CCReason_Automatic];

    [file setType:Type_ASCII atVirtualAddress:baseAddress + NAME_ADDR forLength:32];
    [file setInlineComment:@"name" atVirtualAddress:baseAddress + NAME_ADDR reason:CCReason_Automatic];
    
    [file setType:Type_ASCII atVirtualAddress:baseAddress + COMPANY_ADDR forLength:32];
    [file setInlineComment:@"company" atVirtualAddress:baseAddress + COMPANY_ADDR reason:CCReason_Automatic];
    
    [file setType:Type_Int32 atVirtualAddress:baseAddress + ICON_RES_ID_ADDR forLength:4];
    [file setInlineComment:@"icon_resource_id" atVirtualAddress:baseAddress + ICON_RES_ID_ADDR reason:CCReason_Automatic];

    [file setType:Type_Int32 atVirtualAddress:baseAddress + JUMP_TABLE_ADDR forLength:4];
    [file setInlineComment:@"jump_table_addr" atVirtualAddress:baseAddress + JUMP_TABLE_ADDR reason:CCReason_Automatic];

    [file setType:Type_Int32 atVirtualAddress:baseAddress + FLAGS_ADDR forLength:4];
    [file setInlineComment:@"flags" atVirtualAddress:baseAddress + FLAGS_ADDR reason:CCReason_Automatic];

    [file setType:Type_Int32 atVirtualAddress:baseAddress + NUM_RELOC_ENTRIES_ADDR forLength:4];
    [file setInlineComment:@"num_reloc_entries" atVirtualAddress:baseAddress + NUM_RELOC_ENTRIES_ADDR reason:CCReason_Automatic];

    [file setType:Type_Int8 atVirtualAddress:baseAddress + UUID_ADDR forLength:16];
    NSUUID *appUUID = [[NSUUID alloc] initWithUUIDBytes:header+UUID_ADDR];
    [file setInlineComment:[NSString stringWithFormat:@"UUID: %@", appUUID] atVirtualAddress:baseAddress + UUID_ADDR reason:CCReason_Automatic];
    
    [file setType:Type_Int32 atVirtualAddress:baseAddress + RESOURCE_CRC_ADDR forLength:4];
    [file setInlineComment:@"resource_crc" atVirtualAddress:baseAddress + RESOURCE_CRC_ADDR reason:CCReason_Automatic];

    [file setType:Type_Int32 atVirtualAddress:baseAddress + RESOURCE_TIMESTAMP_ADDR forLength:4];
    [file setInlineComment:@"resource_timestamp" atVirtualAddress:baseAddress + RESOURCE_TIMESTAMP_ADDR reason:CCReason_Automatic];

    [file setType:Type_Int16 atVirtualAddress:baseAddress + VIRTUAL_SIZE_ADDR forLength:2];
    [file setInlineComment:@"virtualSize" atVirtualAddress:baseAddress + VIRTUAL_SIZE_ADDR reason:CCReason_Automatic];

    [file setType:Type_Int16 atVirtualAddress:baseAddress + 130 forLength:2];
    [file setInlineComment:@"padding" atVirtualAddress:baseAddress + 130 reason:CCReason_Automatic];

    // API trampoline (20 bytes, last 4 are pointed at by jump table addr */
    uint32_t jumpTableOffset = OSReadLittleInt32(header, JUMP_TABLE_ADDR);
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
    uint32_t entryPoint = baseAddress + OSReadLittleInt32(header, OFFSET_ADDR);
    [file addEntryPoint:entryPoint];
    [file setName:@"main" forVirtualAddress:entryPoint reason:NCReason_Import];
    [self registerDataTypes:file];
    
    [self performSelectorOnMainThread:@selector(waitForDocument:) withObject:_services.currentDocument waitUntilDone:NO];
    return DIS_OK;
}

- (void)waitForDocument:(NSObject<HPDocument>*)document {
    if (document.backgroundProcessActive) {
        [self performSelector:_cmd withObject:document afterDelay:0.01];
        return;
    }
    NSObject<HPDisassembledFile> *file = document.disassembledFile;
    NSObject<HPProcedure> *trampoline = [file procedureAt:[file findVirtualAddressNamed:kTrampolineFunctionName]];
    if (trampoline == nil || document.backgroundProcessActive) {
        [self performSelector:_cmd withObject:document afterDelay:0.01];
        return;
    }
    [self performSelectorInBackground:@selector(mapAPICalls:) withObject:document];
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
            proc = [file makeProcedureAt:block.from];
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
