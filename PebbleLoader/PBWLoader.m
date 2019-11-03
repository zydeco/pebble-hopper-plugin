//
//  PBWLoader.m
//  PebbleLoader
//
//  Created by Jesús A. Álvarez on 03/11/2019.
//  Copyright © 2019 namedfork. All rights reserved.
//

#import "PBWLoader.h"
#import "unzip.h"

static const NSString *UNZInfoNameKey = @"name";
static const NSString *UNZInfoCommentKey = @"comment";
static const NSString *UNZInfoExtraKey = @"extra";
static const NSString *UNZInfoVersionKey = @"version";
static const NSString *UNZInfoVersionNeededKey = @"versionNeeded";
static const NSString *UNZInfoFlagKey = @"flag";
static const NSString *UNZInfoCompressionMethodKey = @"compressionMethod";
static const NSString *UNZInfoDosDateKey = @"dosDate";
static const NSString *UNZInfoCRCKey = @"crc";
static const NSString *UNZInfoCompressedSizeKey = @"compressedSize";
static const NSString *UNZInfoUncompressedSizeKey = @"uncompressedSize";
static const NSString *UNZInfoDiskNumStartKey = @"diskNumStart";
static const NSString *UNZInfoInternalFileAttributesKey = @"internalFileAttributes";
static const NSString *UNZInfoExternalFileAttributesKey = @"externalFileAttributes";
static const NSString *UNZInfoTMKey = @"tm";

@interface PBWLoader ()
- (uLong)_readData:(void*)buf size:(uLong)size;
- (ZPOS64_T)_tell64;
- (long)_seek64Offset:(ZPOS64_T)offset origin:(int)origin;
- (int)_closeStream;
- (int)_error;
@end

static voidpf PBWLoaderOpen64(voidpf opaque, const void *filename, int mode) {
    PBWLoader *loader = (__bridge PBWLoader*)filename;
    return (__bridge voidpf)loader;
}

static uLong PBWLoaderRead(voidpf opaque, voidpf stream, void *buf, uLong size) {
    PBWLoader *loader = (__bridge PBWLoader*)stream;
    return [loader _readData:buf size:size];
}

static ZPOS64_T PBWLoaderTell64(voidpf opaque, voidpf stream) {
    PBWLoader *loader = (__bridge PBWLoader*)stream;
    return [loader _tell64];
}

static long PBWLoaderSeek64(voidpf opaque, voidpf stream, ZPOS64_T offset, int origin) {
    PBWLoader *loader = (__bridge PBWLoader*)stream;
    return [loader _seek64Offset:offset origin:origin];
}

static int PBWLoaderClose(voidpf opaque, voidpf stream) {
    PBWLoader *loader = (__bridge PBWLoader*)stream;
    return [loader _closeStream];
}

static int PBWLoaderError(voidpf opaque, voidpf stream) {
    PBWLoader *loader = (__bridge PBWLoader*)stream;
    return [loader _error];
}

zlib_filefunc64_def pbwloader_filefuncs = {
    .zopen64_file = PBWLoaderOpen64,
    .zread_file = PBWLoaderRead,
    .zwrite_file = NULL,
    .ztell64_file = PBWLoaderTell64,
    .zseek64_file = PBWLoaderSeek64,
    .zclose_file = PBWLoaderClose,
    .zerror_file = PBWLoaderError,
    .opaque = NULL
};

@implementation PBWLoader
{
    NSData *data;
    NSUInteger dataPos;
    unzFile zf;
}

- (instancetype)initWithData:(NSData *)fileData {
    if ((self = [super init])) {
        data = fileData;
        dataPos = 0;
        zf = unzOpen2_64((__bridge void*)self, &pbwloader_filefuncs);
        if (zf == NULL) {
            return nil;
        }
        _caseSensitive = YES;
    }
    return self;
}

- (void)dealloc {
    if (zf != NULL) {
        unzClose(zf);
    }
}

- (NSUInteger)numberOfEntries {
    if (zf == NULL) @throw [NSException exceptionWithName:NSInvalidArgumentException reason:@"Zip file not open" userInfo:nil];
    unz_global_info64 info;
    unzGetGlobalInfo64(zf, &info);
    return (NSUInteger)info.number_entry;
}

- (NSArray<NSString *> *)entries {
    NSMutableArray *entries = [NSMutableArray arrayWithCapacity:self.numberOfEntries];
    unzGoToFirstFile(zf);
    do {
        NSString *fileName = [self _currentFileInfo][UNZInfoNameKey];
        [entries addObject:fileName];
    } while (unzGoToNextFile(zf) == UNZ_OK);
    return entries;
}

- (BOOL)hasFile:(NSString*)fileName {
    return ([self _locateFile:fileName] == UNZ_OK);
}

- (NSData*)readFile:(NSString*)fileName {
    if ([self _locateFile:fileName] != UNZ_OK) {
        return nil;
    }
    NSDictionary *info = [self _currentFileInfo];
    if (info == nil) {
        return nil;
    }
    if (unzOpenCurrentFile(zf) != UNZ_OK) {
        return nil;
    }
    NSUInteger length = [info[UNZInfoUncompressedSizeKey] unsignedIntegerValue];
    void *data = malloc(length);
    if (unzReadCurrentFile(zf, data, (unsigned int)length) < 0) {
        NSLog(@"could not read file");
        free(data);
        unzCloseCurrentFile(zf);
        return nil;
    }
    unzCloseCurrentFile(zf);
    return [NSData dataWithBytesNoCopy:data length:length freeWhenDone:YES];
}

- (NSInteger)sizeOfFile:(NSString*)fileName {
    if ([self _locateFile:fileName] != UNZ_OK) {
        return NSNotFound;
    }
    return [[self _currentFileInfo][UNZInfoUncompressedSizeKey] integerValue];
}

- (int)_locateFile:(NSString*)fileName {
    return unzLocateFile(zf, fileName.fileSystemRepresentation, _caseSensitive ? 1 : 2);
}

- (NSDictionary*)_currentFileInfo {
    unz_file_info64 info;
    if (unzGetCurrentFileInfo64(zf, &info, NULL, 0, NULL, 0, NULL, 0) != UNZ_OK) {
        return nil;
    }
    char *fileName = alloca(info.size_filename+1);
    bzero(fileName, info.size_filename+1);
    void *extraField = alloca(info.size_file_extra);
    bzero(extraField, info.size_file_extra);
    char *comment = alloca(info.size_file_comment+1);
    bzero(comment, info.size_file_comment+1);
    
    if (unzGetCurrentFileInfo64(zf, NULL, fileName, info.size_filename, extraField, info.size_file_extra, comment, info.size_file_comment) != UNZ_OK) {
        return nil;
    }
    
    return @{
        UNZInfoNameKey: @(fileName),
        UNZInfoCommentKey: @(comment),
        UNZInfoExtraKey: [NSData dataWithBytes:extraField length:info.size_file_extra],
        UNZInfoVersionKey: @(info.version),
        UNZInfoVersionNeededKey: @(info.version_needed),
        UNZInfoFlagKey: @(info.flag),
        UNZInfoCompressionMethodKey: @(info.compression_method),
        UNZInfoDosDateKey: @(info.dosDate),
        UNZInfoCRCKey: @(info.crc),
        UNZInfoCompressedSizeKey: @(info.compressed_size),
        UNZInfoUncompressedSizeKey: @(info.uncompressed_size),
        UNZInfoDiskNumStartKey: @(info.disk_num_start),
        UNZInfoInternalFileAttributesKey: @(info.internal_fa),
        UNZInfoExternalFileAttributesKey: @(info.external_fa),
        UNZInfoTMKey: @{
            @"sec": @(info.tmu_date.tm_sec),
            @"min": @(info.tmu_date.tm_min),
            @"hour": @(info.tmu_date.tm_hour),
            @"mday": @(info.tmu_date.tm_mday),
            @"mon": @(info.tmu_date.tm_mon),
            @"year": @(info.tmu_date.tm_year),
        }
    };
}

- (uLong)_readData:(void *)buf size:(uLong)size {
    NSUInteger maxSize = MIN(size, data.length - dataPos);
    [data getBytes:buf range:NSMakeRange(dataPos, maxSize)];
    dataPos += size;
    return maxSize;
}

- (ZPOS64_T)_tell64 {
    return dataPos;
}

- (long)_seek64Offset:(ZPOS64_T)offset origin:(int)origin {
    switch (origin) {
        case ZLIB_FILEFUNC_SEEK_SET:
            dataPos = offset;
            break;
        case ZLIB_FILEFUNC_SEEK_CUR:
            dataPos += offset;
            break;
        case ZLIB_FILEFUNC_SEEK_END:
            dataPos = data.length + offset;
            break;
    }
    return [self _error];
}

- (int)_error {
    return dataPos <= data.length ? 0 : -1;
}

- (int)_closeStream {
    dataPos = 0;
    return 0;
}

@end
