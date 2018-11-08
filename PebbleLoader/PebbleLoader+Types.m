//
//  PebbleLoader+Types.m
//  PebbleLoader
//
//  Created by Jesús A. Álvarez on 07/11/2018.
//  Copyright © 2018 namedfork. All rights reserved.
//

#import "PebbleLoader.h"
#import <Hopper/Hopper.h>
#import <Hopper/HPTypeDesc.h>
#import <Hopper/HPTypeStructField.h>

@implementation PebbleLoader (Types)

- (void)registerStructDataTypes:(NSObject<HPDisassembledFile>*)file {
    NSObject<HPTypeDesc> *type;
    NSObject<HPTypeStructField> *field;
    
    // GPoint
    type = [file structureType];
    type.name = @"GPoint";
    field = [type addStructureFieldOfType:file.int16Type named:@"x"];
    field.displayFormat = Format_Decimal | Format_Signed;
    field = [type addStructureFieldOfType:file.int16Type named:@"y"];
    field.displayFormat = Format_Decimal | Format_Signed;
    type.singleLineDisplay = YES;
    
    // GSize
    type = [file structureType];
    type.name = @"GSize";
    field = [type addStructureFieldOfType:file.int16Type named:@"w"];
    field.displayFormat = Format_Decimal | Format_Signed;
    field = [type addStructureFieldOfType:file.int16Type named:@"h"];
    field.displayFormat = Format_Decimal | Format_Signed;
    type.singleLineDisplay = YES;
    
    // GRect
    type = [file structureType];
    type.name = @"GRect";
    [type addStructureFieldOfType:[file typeWithName:@"GPoint"] named:@"origin"];
    [type addStructureFieldOfType:[file typeWithName:@"GSize"] named:@"size"];
    type.singleLineDisplay = YES;
    
}

- (void)registerDataTypes:(NSObject<HPDisassembledFile>*)file {
    NSBundle *bundle = [NSBundle bundleForClass:[self class]];
    NSString *path;
    NSError *err = nil;
    
    // enum types
    path = [bundle pathForResource:@"EnumTypes" ofType:@"json"];
    NSDictionary<NSString*,id> *enumTypes = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:path] options:0 error:&err];
    if (err) NSLog(@"Error reading enum types: %@", err);
    [enumTypes enumerateKeysAndObjectsUsingBlock:^(NSString * _Nonnull typeName, id _Nonnull values, BOOL * _Nonnull stop) {
        NSObject<HPTypeDesc> *type = [file enumType];
        type.name = typeName;
        __block int64_t largestValue = 0;
        __block BOOL hasNegativeValues = NO;
        if ([values isKindOfClass:[NSArray class]]) {
            [values enumerateObjectsUsingBlock:^(NSString * _Nonnull name, NSUInteger idx, BOOL * _Nonnull stop) {
                [type addEnumFieldWithName:name andValue:(int64_t)idx];
            }];
            largestValue = [values count] - 1;
        } else if ([values isKindOfClass:[NSDictionary class]]) {
            [values enumerateKeysAndObjectsUsingBlock:^(NSString * _Nonnull name, NSNumber * _Nonnull valueObj, BOOL * _Nonnull stop) {
                int64_t value = (int64_t)valueObj.longLongValue;
                largestValue = MAX(largestValue, value);
                if (value < 0) hasNegativeValues = YES;
                [type addEnumFieldWithName:name andValue:value];
            }];
        }
        if (hasNegativeValues) {
            if (largestValue <= 0x7f) {
                type.enumSize = 4;
            } else if (largestValue <= 0x7fffULL) {
                type.enumSize = 2;
            } else if (largestValue <= 0x7fffffffULL) {
                type.enumSize = 4;
            } else {
                type.enumSize = 8;
            }
        } else {
            if (largestValue < 0x100) {
                type.enumSize = 4;
            } else if (largestValue < 0x10000ULL) {
                type.enumSize = 2;
            } else if (largestValue < 0x100000000ULL) {
                type.enumSize = 4;
            } else {
                type.enumSize = 8;
            }
        }
    }];
    
    // struct types
    path = [bundle pathForResource:@"StructTypes" ofType:@"json"];
    NSArray<NSDictionary<NSString*,id>*> *structTypes = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:path] options:0 error:&err];
    if (err) NSLog(@"Error reading struct types: %@", err);
    for (NSDictionary<NSString*,id> *structDef in structTypes) {
        NSString *structName = structDef[@"name"];
        NSArray<NSString *> *fields = structDef[@"fields"];
        NSObject<HPTypeDesc> *type = [self registerStructureName:structName withFields:fields inFile:file];
        if ([structDef[@"singleLineDisplay"] boolValue]) {
            type.singleLineDisplay = YES;
        }
        if ([structDef[@"incomplete"] boolValue]) {
            type.incompleteType = YES;
        }
    }
}

- (NSString*)typeNameForKey:(NSString*)structKey {
    if ([structKey containsString:@"#"]) {
        return [structKey substringToIndex:[structKey rangeOfString:@"#"].location];
    } else {
        return structKey;
    }
}

- (NSObject<HPTypeDesc>*)registerStructureName:(NSString*)name withFields:(NSArray<NSString*>*)fields inFile:(NSObject<HPDisassembledFile>*)file {
    NSObject<HPTypeDesc> *type = [file structureType];
    type.name = name;
    type.forwardDeclaration = fields.count == 0;
    
    [fields enumerateObjectsUsingBlock:^(NSString * _Nonnull fieldDesc, NSUInteger idx, BOOL * _Nonnull stop) {
        NSUInteger commentIndex = [fieldDesc rangeOfString:@"//"].location;
        NSUInteger spaceIndex = [fieldDesc rangeOfString:@" "].location;
        if (commentIndex == NSNotFound) commentIndex = fieldDesc.length;
        NSString *fieldName = (spaceIndex == NSNotFound) ? [NSString stringWithFormat:@"_field%d", (int)idx] : [fieldDesc substringWithRange:NSMakeRange(spaceIndex + 1, commentIndex - spaceIndex - 1)];
        NSString *typeName = [self typeNameForKey:[fieldDesc substringToIndex:spaceIndex]];
        NSObject<HPTypeDesc> *fieldType = [self typeFromString:typeName inFile:file];
        if (fieldType == nil) {
            NSLog(@"Invalid field type %@ for structure %@", typeName, type.name);
            return;
        }
        // array type
        if ([fieldName containsString:@"["] && [fieldName hasSuffix:@"]"]) {
            NSArray<NSString*> *components = [fieldName componentsSeparatedByString:@"["];
            fieldName = components[0];
            NSInteger count = [components[1] substringToIndex:components[1].length-1].integerValue;
            fieldType = [file arrayTypeOf:fieldType withCount:count];
        }
        NSObject<HPTypeStructField> *field = [type addStructureFieldOfType:fieldType named:fieldName];
        if (commentIndex < fieldDesc.length) {
            if ([fieldDesc characterAtIndex:commentIndex + 2] == ' ') commentIndex++;
            field.comment = [fieldDesc substringFromIndex:commentIndex + 2];
        }
        field.displayFormat = [self displayFormatFromTypeName:typeName];
    }];
    return type;
}

- (ArgFormat)displayFormatFromTypeName:(NSString*)typeName {
    ArgFormat format = Format_Default;
    if ([typeName containsString:@"#"]) {
        NSString *displayFormatDesc = [typeName substringFromIndex:[typeName rangeOfString:@"#"].location+1];
        switch ([displayFormatDesc characterAtIndex:displayFormatDesc.length-1]) {
            case 'x': format = Format_Hexadecimal; break;
            case 'd': format = Format_Decimal; break;
            case 'o': format = Format_Octal; break;
            case 'c': format = Format_Character; break;
            case 'l': format = Format_StackVariable; break;
            case '+': format = Format_Offset; break;
            case 'p': format = Format_Address; break;
            case 'f': format = Format_Float; break;
            case 'b': format = Format_Binary; break;
            case 'S': format = Format_Structured; break;
            case 'E': format = Format_Enum; break;
            case '*': format = Format_AddressDiff;
            default:
                break;
        }
        if ([displayFormatDesc containsString:@"-"]) {
            format |= Format_Negate;
        }
        if ([displayFormatDesc containsString:@"s"]) {
            format |= Format_Signed;
        }
        if ([displayFormatDesc containsString:@"0"]) {
            format |= Format_LeadingZeroes;
        }
    }
    return format;
}

- (NSObject<HPTypeDesc>*)typeFromString:(NSString*)typeName inFile:(NSObject<HPDisassembledFile>*)file {
    BOOL isPointer = NO;
    if ([typeName hasSuffix:@"*"]) {
        isPointer = YES;
        typeName = [typeName substringToIndex:typeName.length-1];
    }
    SEL selector = NSSelectorFromString([typeName stringByAppendingString:@"Type"]);
    NSObject<HPTypeDesc>* type;
    if ([file respondsToSelector:selector]) {
        type = [file performSelector:selector];
    } else {
        type = [file typeWithName:typeName];
    }
    if (isPointer) {
        type = [file pointerTypeOn:type];
    }
    return type;
}

@end
