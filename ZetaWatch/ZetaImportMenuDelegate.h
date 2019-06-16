//
//  ZetaImportMenuDelegate.h
//  ZetaWatch
//
//  Created by cbreak on 19.06.02.
//  Copyright © 2019 the-color-black.net. All rights reserved.
//

#ifndef ZetaImportMenuDelegate_h
#define ZetaImportMenuDelegate_h

#import <Cocoa/Cocoa.h>

#import "ZetaAuthorization.h"
#import "ZetaBaseDelegate.h"

@interface ZetaImportMenuDelegate : ZetaBaseDelegate <NSMenuDelegate>

@property (weak) IBOutlet NSMenu * importMenu;

@end

#endif /* ZetaImportMenuDelegate_h */
