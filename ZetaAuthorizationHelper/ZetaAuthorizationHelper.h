//
//  ZetaAuthorizationHelper.h
//  ZetaAuthorizationHelper
//
//  Created by cbreak on 18.01.01.
//  Copyright © 2018 the-color-black.net. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface ZetaAuthorizationHelper : NSObject

@property (copy) NSArray * prefixPaths;

- (id)init;
- (void)run;

@end
