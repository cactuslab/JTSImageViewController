//
//  JTSImageViewController.h
//
//
//  Created by Jared Sinclair on 3/28/14.
//  Copyright (c) 2014 Nice Boy LLC. All rights reserved.
//

@import UIKit;

#import "JTSImageInfo.h"

///--------------------------------------------------------------------------------------------------------------------
/// Definitions
///--------------------------------------------------------------------------------------------------------------------

///--------------------------------------------------------------------------------------------------------------------
/// JTSImageViewController
///--------------------------------------------------------------------------------------------------------------------

@interface JTSImageViewController : UIViewController

@property (strong, nonatomic, readonly) JTSImageInfo *imageInfo;

@property (strong, nonatomic, readonly) UIImage *image;

/**
 Designated initializer.
 
 @param imageInfo The source info for image and transition metadata. Required.
 
 */
- (instancetype)initWithImageInfo:(JTSImageInfo *)imageInfo;

/**
 JTSImageViewController is presented from viewController as a UIKit modal view controller.
 
 It's first presented as a full-screen modal *without* animation. At this stage the view controller
 is merely displaying a snapshot of viewController's topmost parentViewController's view.
 
 Next, there is an animated transition to a full-screen image viewer.
 */
- (void)showFromViewController:(UIViewController *)viewController;

/**
 Dismisses the image viewer. Must not be called while previous presentation or dismissal is still in flight.
 */
- (void)dismiss:(BOOL)animated;

@end








