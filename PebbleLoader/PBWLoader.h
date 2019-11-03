//
//  PBWLoader.h
//  PebbleLoader
//
//  Created by Jesús A. Álvarez on 03/11/2019.
//  Copyright © 2019 namedfork. All rights reserved.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface PBWLoader : NSObject

@property (nonatomic, assign) BOOL caseSensitive;
@property (nonatomic, readonly) NSUInteger numberOfEntries;
@property (nonatomic, readonly) NSArray<NSString*> *entries;

- (instancetype)initWithData:(NSData*)data;
- (BOOL)hasFile:(NSString*)fileName;
- (NSData*)readFile:(NSString*)fileName;
- (NSInteger)sizeOfFile:(NSString*)fileName;

@end

NS_ASSUME_NONNULL_END
