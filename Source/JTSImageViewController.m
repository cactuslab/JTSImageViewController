//
//  JTSImageViewController.m
//
//
//  Created by Jared Sinclair on 3/28/14.
//  Copyright (c) 2014 Nice Boy LLC. All rights reserved.
//

#import "JTSImageViewController.h"

#import "JTSSimpleImageDownloader.h"

CG_INLINE CGFLOAT_TYPE JTSImageFloatAbs(CGFLOAT_TYPE aFloat) {
#if CGFLOAT_IS_DOUBLE
    return fabs(aFloat);
#else
    return fabsf(aFloat);
#endif
}

///--------------------------------------------------------------------------------------------------------------------
/// Definitions
///--------------------------------------------------------------------------------------------------------------------

// Private Constants
static CGFloat const JTSImageViewController_TargetZoomForDoubleTap = 3.0f;
static CGFloat const JTSImageViewController_TransitionAnimationDuration = 0.3f;
static CGFloat const JTSImageViewController_MinimumFlickDismissalVelocity = 800.0f;

typedef struct {
    CGRect startingReferenceFrameForThumbnail;
    CGRect startingReferenceFrameForThumbnailInPresentingViewControllersOriginalOrientation;
    CGPoint startingReferenceCenterForThumbnail;
    UIInterfaceOrientation startingInterfaceOrientation;
    BOOL presentingViewControllerPresentedFromItsUnsupportedOrientation;
} JTSImageViewControllerStartingInfo;

typedef struct {
    BOOL isAnimatingAPresentationOrDismissal;
    BOOL isDismissing;
    BOOL isTransitioningFromInitialModalToInteractiveState;
    BOOL viewHasAppeared;
    BOOL isRotating;
    BOOL isPresented;
    BOOL rotationTransformIsDirty;
    BOOL imageIsFlickingAwayForDismissal;
    BOOL isDraggingImage;
    BOOL scrollViewIsAnimatingAZoom;
    BOOL imageIsBeingReadFromDisk;
    BOOL isManuallyResizingTheScrollViewFrame;
    BOOL imageDownloadFailed;
} JTSImageViewControllerFlags;

#define USE_DEBUG_SLOW_ANIMATIONS 0

///--------------------------------------------------------------------------------------------------------------------
/// Anonymous Category
///--------------------------------------------------------------------------------------------------------------------

@interface JTSImageViewController ()
<
    UIScrollViewDelegate,
    UIViewControllerTransitioningDelegate,
    UIGestureRecognizerDelegate
>

// General Info
@property (strong, nonatomic, readwrite) JTSImageInfo *imageInfo;
@property (strong, nonatomic, readwrite) UIImage *image;
@property (assign, nonatomic) JTSImageViewControllerStartingInfo startingInfo;
@property (assign, nonatomic) JTSImageViewControllerFlags flags;

// Autorotation
@property (assign, nonatomic) UIInterfaceOrientation lastUsedOrientation;
@property (assign, nonatomic) CGAffineTransform currentSnapshotRotationTransform;

// Views
@property (strong, nonatomic) UIView *blurBackgroundView;
@property (strong, nonatomic) UIView *progressContainer;
@property (strong, nonatomic) UIView *outerContainerForScrollView;
@property (strong, nonatomic) UIView *blackBackdrop;
@property (strong, nonatomic) UIImageView *imageView;
@property (strong, nonatomic) UIScrollView *scrollView;
@property (strong, nonatomic) UIProgressView *progressView;
@property (strong, nonatomic) UIActivityIndicatorView *spinner;

// Gesture Recognizers
@property (strong, nonatomic) UITapGestureRecognizer *singleTapperPhoto;
@property (strong, nonatomic) UITapGestureRecognizer *doubleTapperPhoto;
@property (strong, nonatomic) UITapGestureRecognizer *singleTapperText;
@property (strong, nonatomic) UIPanGestureRecognizer *panRecognizer;

// UIDynamics
@property (strong, nonatomic) UIDynamicAnimator *animator;
@property (strong, nonatomic) UIAttachmentBehavior *attachmentBehavior;
@property (assign, nonatomic) CGPoint imageDragStartingPoint;
@property (assign, nonatomic) UIOffset imageDragOffsetFromActualTranslation;
@property (assign, nonatomic) UIOffset imageDragOffsetFromImageCenter;

// Image Downloading
@property (strong, nonatomic) NSURLSessionDataTask *imageDownloadDataTask;
@property (strong, nonatomic) NSTimer *downloadProgressTimer;

@end

///--------------------------------------------------------------------------------------------------------------------
/// Implementation
///--------------------------------------------------------------------------------------------------------------------

@implementation JTSImageViewController

#pragma mark - Public

- (instancetype)initWithImageInfo:(JTSImageInfo *)imageInfo {
    
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        self.modalPresentationStyle = UIModalPresentationOverFullScreen;
        
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(deviceOrientationDidChange:) name:UIDeviceOrientationDidChangeNotification object:nil];
        _imageInfo = imageInfo;
        _currentSnapshotRotationTransform = CGAffineTransformIdentity;
        [self setupImageAndDownloadIfNecessary:imageInfo];
    }
    return self;
}

- (void)showFromViewController:(UIViewController *)viewController {
    [self showImageViewerByExpandingFromOriginalPositionFromViewController:viewController];
}

- (void)dismiss:(BOOL)animated {
    
    // Early Return!
    if (_flags.isPresented == NO) {
        return;
    }
    
    _flags.isPresented = NO;
    
    if (_flags.imageIsFlickingAwayForDismissal) {
        [self dismissByCleaningUpAfterImageWasFlickedOffscreen];
    } else {
        [self dismissByCollapsingImageBackToOriginalPosition];
    }
}

#pragma mark - NSObject

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIDeviceOrientationDidChangeNotification object:nil];
    [_imageDownloadDataTask cancel];
    [self cancelProgressTimer];
}

#pragma mark - UIViewController

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    
    /*
     iOS 8 changes the behavior of autorotation when presenting a
     modal view controller whose supported orientations outnumber
     the orientations of the presenting view controller.
     
     E.g., when a portrait-only iPhone view controller presents
     JTSImageViewController while the **device** is oriented in
     landscape, on iOS 8 the modal view controller presents straight
     into landscape, whereas on iOS 7 the interface orientation
     of the presenting view controller is preserved.
     
     In my judgement the iOS 7 behavior is preferable. It also simplifies
     the rotation corrections during presentation. - August 31, 2014 JTS.
     */
    
    NSUInteger mask;
    
    if (self.flags.viewHasAppeared == NO) {
        switch ([UIApplication sharedApplication].statusBarOrientation) {
            case UIInterfaceOrientationLandscapeLeft:
                mask = UIInterfaceOrientationMaskLandscapeLeft;
                break;
            case UIInterfaceOrientationLandscapeRight:
                mask = UIInterfaceOrientationMaskLandscapeRight;
                break;
            case UIInterfaceOrientationPortrait:
                mask = UIInterfaceOrientationMaskPortrait;
                break;
            case UIInterfaceOrientationPortraitUpsideDown:
                mask = UIInterfaceOrientationMaskPortraitUpsideDown;
                break;
            default:
                mask = UIInterfaceOrientationPortrait;
                break;
        }
    }
    else if ([UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        mask = UIInterfaceOrientationMaskAll;
    } else {
        mask = UIInterfaceOrientationMaskAllButUpsideDown;
    }
    return mask;
}

- (BOOL)shouldAutorotate {
    return (_flags.isAnimatingAPresentationOrDismissal == NO);
}

- (BOOL)prefersStatusBarHidden {
    return YES;
}

- (UIStatusBarAnimation)preferredStatusBarUpdateAnimation {
    return UIStatusBarAnimationFade;
}

- (UIModalTransitionStyle)modalTransitionStyle {
    return UIModalTransitionStyleCrossDissolve;
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    return UIStatusBarStyleLightContent;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    
    UIBlurEffect *blurEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
    UIVisualEffectView *blurBackgroundView = [[UIVisualEffectView alloc] initWithEffect:blurEffect];
    
    blurBackgroundView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    blurBackgroundView.alpha = 0.0;
    blurBackgroundView.frame = self.view.bounds;
    
    [self.view addSubview:blurBackgroundView];
    
    self.blurBackgroundView = blurBackgroundView;
    
    self.view.autoresizingMask = UIViewAutoresizingFlexibleHeight | UIViewAutoresizingFlexibleWidth;
    
    self.blackBackdrop = [[UIView alloc] initWithFrame:CGRectInset(self.view.bounds, -512, -512)];
    self.blackBackdrop.backgroundColor = [UIColor blackColor];
    self.blackBackdrop.alpha = 0;
    [self.view addSubview:self.blackBackdrop];
    
    self.scrollView = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    self.scrollView.delegate = self;
    self.scrollView.zoomScale = 1.0f;
    self.scrollView.maximumZoomScale = 8.0f;
    self.scrollView.scrollEnabled = NO;
    self.scrollView.isAccessibilityElement = YES;
    self.scrollView.accessibilityLabel = self.accessibilityLabel;
    self.scrollView.accessibilityHint = [self accessibilityHintZoomedOut];
    [self.view addSubview:self.scrollView];
    
    CGRect referenceFrameInWindow = [self.imageInfo.referenceView convertRect:self.imageInfo.referenceRect toView:nil];
    CGRect referenceFrameInMyView = [self.view convertRect:referenceFrameInWindow fromView:nil];
    
    self.imageView = [[UIImageView alloc] initWithFrame:referenceFrameInMyView];
    self.imageView.layer.cornerRadius = self.imageInfo.referenceCornerRadius;
    self.imageView.contentMode = UIViewContentModeScaleAspectFill;
    self.imageView.userInteractionEnabled = YES;
    self.imageView.isAccessibilityElement = NO;
    self.imageView.clipsToBounds = YES;
    self.imageView.layer.allowsEdgeAntialiasing = YES;
    
    // We'll add the image view to either the scroll view
    // or the parent view, based on the transition style
    // used in the "show" method.
    // After that transition completes, the image view will be
    // added to the scroll view.
    
    [self setupImageModeGestureRecognizers];
    
    self.progressContainer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 128.0f, 128.0f)];
    [self.view addSubview:self.progressContainer];
    self.progressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    self.progressView.progress = 0;
    self.progressView.tintColor = [UIColor whiteColor];
    self.progressView.trackTintColor = [UIColor darkGrayColor];
    CGRect progressFrame = self.progressView.frame;
    progressFrame.size.width = 128.0f;
    self.progressView.frame = progressFrame;
    self.progressView.center = CGPointMake(64.0f, 64.0f);
    self.progressView.alpha = 0;
    [self.progressContainer addSubview:self.progressView];
    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhiteLarge];
    self.spinner.center = CGPointMake(64.0f, 64.0f);
    [self.spinner startAnimating];
    [self.progressContainer addSubview:self.spinner];
    self.progressContainer.alpha = 0;
    
    self.animator = [[UIDynamicAnimator alloc] initWithReferenceView:self.scrollView];
    
    if (self.image) {
        [self updateInterfaceWithImage:self.image];
    }
}

- (void)viewDidLayoutSubviews {
    [self updateLayoutsForCurrentOrientation];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (self.lastUsedOrientation != [UIApplication sharedApplication].statusBarOrientation) {
        self.lastUsedOrientation = [UIApplication sharedApplication].statusBarOrientation;
        _flags.rotationTransformIsDirty = YES;
        [self updateLayoutsForCurrentOrientation];
    }
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    _flags.viewHasAppeared = YES;
}

- (void)willRotateToInterfaceOrientation:(UIInterfaceOrientation)toInterfaceOrientation duration:(NSTimeInterval)duration {
    self.lastUsedOrientation = toInterfaceOrientation;
    _flags.rotationTransformIsDirty = YES;
    _flags.isRotating = YES;
}

- (void)willAnimateRotationToInterfaceOrientation:(UIInterfaceOrientation)toInterfaceOrientation duration:(NSTimeInterval)duration {
    [self cancelCurrentImageDrag:NO];
    [self updateLayoutsForCurrentOrientation];
    [self updateDimmingViewForCurrentZoomScale:NO];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, duration * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        _flags.isRotating = NO;
    });
}

#if __IPHONE_OS_VERSION_MAX_ALLOWED > __IPHONE_7_1
- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    _flags.rotationTransformIsDirty = YES;
    _flags.isRotating = YES;
    typeof(self) __weak weakSelf = self;
    [coordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        typeof(self) strongSelf = weakSelf;
        [strongSelf cancelCurrentImageDrag:NO];
        [strongSelf updateLayoutsForCurrentOrientation];
        [strongSelf updateDimmingViewForCurrentZoomScale:NO];
    } completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        typeof(self) strongSelf = weakSelf;
        strongSelf.lastUsedOrientation = [UIApplication sharedApplication].statusBarOrientation;
        JTSImageViewControllerFlags flags = strongSelf.flags;
        flags.isRotating = NO;
        strongSelf.flags = flags;
    }];
}
#endif

- (void)deviceOrientationDidChange:(NSNotification *)notification {
    
    NSString *systemVersion = [UIDevice currentDevice].systemVersion;
    if (systemVersion.floatValue < 8.0) {
        // Early Return
        return;
    }
    /*
     viewWillTransitionToSize:withTransitionCoordinator: is not called when rotating from
     one landscape orientation to the other (or from one portrait orientation to another). 
     This makes it difficult to preserve the desired behavior of JTSImageViewController. 
     We want the background snapshot to maintain the illusion that it never rotates. The 
     only other way to ensure that the background snapshot stays in the correct orientation 
     is to listen for this notification and respond when we've detected a landscape-to-landscape rotation.
    */
    UIDeviceOrientation deviceOrientation = [UIDevice currentDevice].orientation;
    BOOL landscapeToLandscape = UIDeviceOrientationIsLandscape(deviceOrientation) && UIInterfaceOrientationIsLandscape(self.lastUsedOrientation);
    BOOL portraitToPortrait = UIDeviceOrientationIsPortrait(deviceOrientation) && UIInterfaceOrientationIsPortrait(self.lastUsedOrientation);
    if (landscapeToLandscape || portraitToPortrait) {
        UIInterfaceOrientation newInterfaceOrientation = (UIInterfaceOrientation)deviceOrientation;
        if (newInterfaceOrientation != self.lastUsedOrientation) {
            self.lastUsedOrientation = newInterfaceOrientation;
            _flags.rotationTransformIsDirty = YES;
            _flags.isRotating = YES;
            typeof(self) __weak weakSelf = self;
            [UIView animateWithDuration:0.6 animations:^{
                typeof(self) strongSelf = weakSelf;
                [strongSelf cancelCurrentImageDrag:NO];
                [strongSelf updateLayoutsForCurrentOrientation];
                [strongSelf updateDimmingViewForCurrentZoomScale:NO];
            } completion:^(BOOL finished) {
                typeof(self) strongSelf = weakSelf;
                JTSImageViewControllerFlags flags = strongSelf.flags;
                flags.isRotating = NO;
                strongSelf.flags = flags;
            }];
        }
    }
}

#pragma mark - Setup

- (void)setupImageAndDownloadIfNecessary:(JTSImageInfo *)imageInfo {
    if (imageInfo.image) {
        self.image = imageInfo.image;
    }
    else {
        
        self.image = imageInfo.placeholderImage;
        
        BOOL fromDisk = [imageInfo.imageURL.absoluteString hasPrefix:@"file://"];
        _flags.imageIsBeingReadFromDisk = fromDisk;
        
        typeof(self) __weak weakSelf = self;
        NSURLSessionDataTask *task = [JTSSimpleImageDownloader downloadImageForURL:imageInfo.imageURL canonicalURL:imageInfo.canonicalImageURL completion:^(UIImage *image) {
            typeof(self) strongSelf = weakSelf;
            [strongSelf cancelProgressTimer];
            if (image) {
                if (strongSelf.isViewLoaded) {
                    [strongSelf updateInterfaceWithImage:image];
                } else {
                    strongSelf.image = image;
                }
            } else if (strongSelf.image == nil) {
                _flags.imageDownloadFailed = YES;
                if (_flags.isPresented && _flags.isAnimatingAPresentationOrDismissal == NO) {
                    [strongSelf dismiss:YES];
                }
                // If we're still presenting, at the end of presentation we'll auto dismiss.
            }
        }];
        
        self.imageDownloadDataTask = task;
        
        [self startProgressTimer];
    }
}

- (void)setupImageModeGestureRecognizers {
    
    self.doubleTapperPhoto = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(imageDoubleTapped:)];
    self.doubleTapperPhoto.numberOfTapsRequired = 2;
    self.doubleTapperPhoto.delegate = self;
    
    self.singleTapperPhoto = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(imageSingleTapped:)];
    [self.singleTapperPhoto requireGestureRecognizerToFail:self.doubleTapperPhoto];
    self.singleTapperPhoto.delegate = self;
    
    [self.view addGestureRecognizer:self.singleTapperPhoto];
    [self.view addGestureRecognizer:self.doubleTapperPhoto];
    
    self.panRecognizer = [[UIPanGestureRecognizer alloc] init];
    self.panRecognizer.maximumNumberOfTouches = 1;
    [self.panRecognizer addTarget:self action:@selector(dismissingPanGestureRecognizerPanned:)];
    self.panRecognizer.delegate = self;
    [self.scrollView addGestureRecognizer:self.panRecognizer];
}

#pragma mark - Presentation

- (void)showImageViewerByExpandingFromOriginalPositionFromViewController:(UIViewController *)viewController {
    
    _flags.isAnimatingAPresentationOrDismissal = YES;
    self.view.userInteractionEnabled = NO;
    
    _startingInfo.startingInterfaceOrientation = [UIApplication sharedApplication].statusBarOrientation;
    
    self.lastUsedOrientation = [UIApplication sharedApplication].statusBarOrientation;
    CGRect referenceFrameInWindow = [self.imageInfo.referenceView convertRect:self.imageInfo.referenceRect toView:nil];
    
    _startingInfo.startingReferenceFrameForThumbnailInPresentingViewControllersOriginalOrientation = [self.view convertRect:referenceFrameInWindow fromView:nil];
    
    if (self.imageInfo.referenceContentMode) {
        self.imageView.contentMode = self.imageInfo.referenceContentMode;
    }
    
    // This will be moved into the scroll view after
    // the transition finishes.
    [self.view addSubview:self.imageView];
    
    [viewController presentViewController:self animated:NO completion:^{
        
        if ([UIApplication sharedApplication].statusBarOrientation != _startingInfo.startingInterfaceOrientation) {
            _startingInfo.presentingViewControllerPresentedFromItsUnsupportedOrientation = YES;
        }
        
        CGRect referenceFrameInMyView = [self.view convertRect:referenceFrameInWindow fromView:nil];
        _startingInfo.startingReferenceFrameForThumbnail = referenceFrameInMyView;
        self.imageView.frame = referenceFrameInMyView;
        self.imageView.layer.cornerRadius = self.imageInfo.referenceCornerRadius;
        [self updateScrollViewAndImageViewForCurrentMetrics];
        
        BOOL mustRotateDuringTransition = ([UIApplication sharedApplication].statusBarOrientation != _startingInfo.startingInterfaceOrientation);
        if (mustRotateDuringTransition) {
            CGRect newStartingRect = [self.view convertRect:_startingInfo.startingReferenceFrameForThumbnail toView:self.view];
            self.imageView.frame = newStartingRect;
            [self updateScrollViewAndImageViewForCurrentMetrics];
            self.imageView.transform = self.view.transform;
            CGPoint centerInRect = CGPointMake(_startingInfo.startingReferenceFrameForThumbnail.origin.x
                                               +_startingInfo.startingReferenceFrameForThumbnail.size.width/2.0f,
                                               _startingInfo.startingReferenceFrameForThumbnail.origin.y
                                               +_startingInfo.startingReferenceFrameForThumbnail.size.height/2.0f);
            self.imageView.center = centerInRect;
        }
        
        CGFloat duration = JTSImageViewController_TransitionAnimationDuration;
        if (USE_DEBUG_SLOW_ANIMATIONS == 1) {
            duration *= 4;
        }
        
        __weak JTSImageViewController *weakSelf = self;
        
        // Have to dispatch ahead two runloops,
        // or else the image view changes above won't be
        // committed prior to the animations below.
        //
        // Dispatching only one runloop ahead doesn't fix
        // the issue on certain devices.
        //
        // This issue also seems to be triggered by only
        // certain kinds of interactions with certain views,
        // especially when a UIButton is the reference
        // for the JTSImageInfo.
        //
        dispatch_async(dispatch_get_main_queue(), ^{
            dispatch_async(dispatch_get_main_queue(), ^{
                
                CABasicAnimation *cornerRadiusAnimation = [CABasicAnimation animationWithKeyPath:@"cornerRadius"];
                cornerRadiusAnimation.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
                cornerRadiusAnimation.fromValue = @(weakSelf.imageView.layer.cornerRadius);
                cornerRadiusAnimation.toValue = @(0.0);
                cornerRadiusAnimation.duration = duration;
                [weakSelf.imageView.layer addAnimation:cornerRadiusAnimation forKey:@"cornerRadius"];
                weakSelf.imageView.layer.cornerRadius = 0.0;
                
                [UIView
                 animateWithDuration:duration
                 delay:0
                 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseInOut
                 animations:^{
                     
                     _flags.isTransitioningFromInitialModalToInteractiveState = YES;
                     
                     [weakSelf setNeedsStatusBarAppearanceUpdate];
                     
                     weakSelf.blurBackgroundView.alpha = 1.0;
                     
                     weakSelf.blackBackdrop.alpha = self.alphaForBackgroundDimmingOverlay;
                     
                     if (mustRotateDuringTransition) {
                         weakSelf.imageView.transform = CGAffineTransformIdentity;
                     }
                     
                     CGRect endFrameForImageView;
                     if (weakSelf.image) {
                         endFrameForImageView = [weakSelf resizedFrameForAutorotatingImageView:weakSelf.image.size];
                     } else {
                         endFrameForImageView = [weakSelf resizedFrameForAutorotatingImageView:weakSelf.imageInfo.referenceRect.size];
                     }
                     weakSelf.imageView.frame = endFrameForImageView;
                     
                     CGPoint endCenterForImageView = CGPointMake(weakSelf.view.bounds.size.width/2.0f, weakSelf.view.bounds.size.height/2.0f);
                     weakSelf.imageView.center = endCenterForImageView;
                     
                     if (weakSelf.image == nil) {
                         weakSelf.progressContainer.alpha = 1.0f;
                     }
                     
                 } completion:^(BOOL finished) {
                     
                     _flags.isManuallyResizingTheScrollViewFrame = YES;
                     weakSelf.scrollView.frame = weakSelf.view.bounds;
                     _flags.isManuallyResizingTheScrollViewFrame = NO;
                     [weakSelf.scrollView addSubview:weakSelf.imageView];
                     
                     _flags.isTransitioningFromInitialModalToInteractiveState = NO;
                     _flags.isAnimatingAPresentationOrDismissal = NO;
                     _flags.isPresented = YES;
                     
                     [weakSelf updateScrollViewAndImageViewForCurrentMetrics];
                     
                     if (_flags.imageDownloadFailed) {
                         [weakSelf dismiss:YES];
                     } else {
                         weakSelf.view.userInteractionEnabled = YES;
                     }
                 }];
            });
        });
    }];
}

#pragma mark - Options Delegate Convenience

- (CGFloat)alphaForBackgroundDimmingOverlay {
    
    return 0;
}

#pragma mark - Dismissal

- (void)dismissByCollapsingImageBackToOriginalPosition {
    
    self.view.userInteractionEnabled = NO;
    _flags.isAnimatingAPresentationOrDismissal = YES;
    _flags.isDismissing = YES;
    
    CGRect imageFrame = [self.view convertRect:self.imageView.frame fromView:self.scrollView];
    self.imageView.autoresizingMask = UIViewAutoresizingNone;
    self.imageView.transform = CGAffineTransformIdentity;
    self.imageView.layer.transform = CATransform3DIdentity;
    [self.imageView removeFromSuperview];
    self.imageView.frame = imageFrame;
    [self.view addSubview:self.imageView];
    [self.scrollView removeFromSuperview];
    self.scrollView = nil;
    
    __weak JTSImageViewController *weakSelf = self;
    
    // Have to dispatch after or else the image view changes above won't be
    // committed prior to the animations below. A single dispatch_async(dispatch_get_main_queue()
    // wouldn't work under certain scrolling conditions, so it has to be an ugly
    // two runloops ahead.
    dispatch_async(dispatch_get_main_queue(), ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            
            CGFloat duration = JTSImageViewController_TransitionAnimationDuration;
            if (USE_DEBUG_SLOW_ANIMATIONS == 1) {
                duration *= 4;
            }
            
            CABasicAnimation *cornerRadiusAnimation = [CABasicAnimation animationWithKeyPath:@"cornerRadius"];
            cornerRadiusAnimation.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
            cornerRadiusAnimation.fromValue = @(0.0);
            cornerRadiusAnimation.toValue = @(weakSelf.imageInfo.referenceCornerRadius);
            cornerRadiusAnimation.duration = duration;
            [weakSelf.imageView.layer addAnimation:cornerRadiusAnimation forKey:@"cornerRadius"];
            weakSelf.imageView.layer.cornerRadius = weakSelf.imageInfo.referenceCornerRadius;
            
            [UIView animateWithDuration:duration delay:0 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseInOut animations:^{
                
                weakSelf.blackBackdrop.alpha = 0;
                
                weakSelf.blurBackgroundView.alpha = 0;
                
                BOOL mustRotateDuringTransition = ([UIApplication sharedApplication].statusBarOrientation != _startingInfo.startingInterfaceOrientation);
                if (mustRotateDuringTransition) {
                    CGRect newEndingRect;
                    CGPoint centerInRect;
                    if (_startingInfo.presentingViewControllerPresentedFromItsUnsupportedOrientation) {
                        CGRect rectToConvert = _startingInfo.startingReferenceFrameForThumbnailInPresentingViewControllersOriginalOrientation;
                        CGRect rectForCentering = [weakSelf.view convertRect:rectToConvert toView:weakSelf.view];
                        centerInRect = CGPointMake(rectForCentering.origin.x+rectForCentering.size.width/2.0f,
                                                   rectForCentering.origin.y+rectForCentering.size.height/2.0f);
                        newEndingRect = _startingInfo.startingReferenceFrameForThumbnailInPresentingViewControllersOriginalOrientation;
                    } else {
                        newEndingRect = _startingInfo.startingReferenceFrameForThumbnail;
                        CGRect rectForCentering = [weakSelf.view convertRect:_startingInfo.startingReferenceFrameForThumbnail toView:weakSelf.view];
                        centerInRect = CGPointMake(rectForCentering.origin.x+rectForCentering.size.width/2.0f,
                                                   rectForCentering.origin.y+rectForCentering.size.height/2.0f);
                    }
                    weakSelf.imageView.frame = newEndingRect;
                    weakSelf.imageView.transform = weakSelf.currentSnapshotRotationTransform;
                    weakSelf.imageView.center = centerInRect;
                } else {
                    if (_startingInfo.presentingViewControllerPresentedFromItsUnsupportedOrientation) {
                        weakSelf.imageView.frame = _startingInfo.startingReferenceFrameForThumbnailInPresentingViewControllersOriginalOrientation;
                    } else {
                        weakSelf.imageView.frame = _startingInfo.startingReferenceFrameForThumbnail;
                    }
                    
                    // Rotation not needed, so fade the status bar back in. Looks nicer.
                    [weakSelf setNeedsStatusBarAppearanceUpdate];
                }
            } completion:^(BOOL finished) {
                
                [weakSelf.presentingViewController dismissViewControllerAnimated:NO completion:nil];
            }];
        });
    });
}

- (void)dismissByCleaningUpAfterImageWasFlickedOffscreen {
    
    self.view.userInteractionEnabled = NO;
    _flags.isAnimatingAPresentationOrDismissal = YES ;
    _flags.isDismissing = YES;
    
    __weak JTSImageViewController *weakSelf = self;
    
    CGFloat duration = JTSImageViewController_TransitionAnimationDuration;
    if (USE_DEBUG_SLOW_ANIMATIONS == 1) {
        duration *= 4;
    }
    
    [UIView animateWithDuration:duration delay:0 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseInOut animations:^{
        
        weakSelf.blackBackdrop.alpha = 0;
        weakSelf.blurBackgroundView.alpha = 0;
        weakSelf.scrollView.alpha = 0;
        [weakSelf setNeedsStatusBarAppearanceUpdate];
    } completion:^(BOOL finished) {
        [weakSelf.presentingViewController dismissViewControllerAnimated:NO completion:nil];
    }];
}

#pragma mark - Interface Updates

- (void)updateInterfaceWithImage:(UIImage *)image {
    
    if (image) {
        self.image = image;
        self.imageView.image = image;
        self.progressContainer.alpha = 0;
        
        self.imageView.backgroundColor = [UIColor clearColor];
        
        // Don't update the layouts during a drag.
        if (_flags.isDraggingImage == NO) {
            [self updateLayoutsForCurrentOrientation];
        }
    }
}

- (void)updateLayoutsForCurrentOrientation {
    
    [self updateScrollViewAndImageViewForCurrentMetrics];
    self.progressContainer.center = CGPointMake(self.view.bounds.size.width/2.0f, self.view.bounds.size.height/2.0f);
    
    CGAffineTransform transform = CGAffineTransformIdentity;
    
    if (_startingInfo.startingInterfaceOrientation == UIInterfaceOrientationPortrait) {
        switch ([UIApplication sharedApplication].statusBarOrientation) {
            case UIInterfaceOrientationLandscapeLeft:
                transform = CGAffineTransformMakeRotation(M_PI/2.0f);
                break;
            case UIInterfaceOrientationLandscapeRight:
                transform = CGAffineTransformMakeRotation(-M_PI/2.0f);
                break;
            case UIInterfaceOrientationPortrait:
                transform = CGAffineTransformIdentity;
                break;
            case UIInterfaceOrientationPortraitUpsideDown:
                transform = CGAffineTransformMakeRotation(M_PI);
                break;
            default:
                break;
        }
    }
    else if (_startingInfo.startingInterfaceOrientation == UIInterfaceOrientationPortraitUpsideDown) {
        switch ([UIApplication sharedApplication].statusBarOrientation) {
            case UIInterfaceOrientationLandscapeLeft:
                transform = CGAffineTransformMakeRotation(-M_PI/2.0f);
                break;
            case UIInterfaceOrientationLandscapeRight:
                transform = CGAffineTransformMakeRotation(M_PI/2.0f);
                break;
            case UIInterfaceOrientationPortrait:
                transform = CGAffineTransformMakeRotation(M_PI);
                break;
            case UIInterfaceOrientationPortraitUpsideDown:
                transform = CGAffineTransformIdentity;
                break;
            default:
                break;
        }
    }
    else if (_startingInfo.startingInterfaceOrientation == UIInterfaceOrientationLandscapeLeft) {
        switch ([UIApplication sharedApplication].statusBarOrientation) {
            case UIInterfaceOrientationLandscapeLeft:
                transform = CGAffineTransformIdentity;
                break;
            case UIInterfaceOrientationLandscapeRight:
                transform = CGAffineTransformMakeRotation(M_PI);
                break;
            case UIInterfaceOrientationPortrait:
                transform = CGAffineTransformMakeRotation(-M_PI/2.0f);
                break;
            case UIInterfaceOrientationPortraitUpsideDown:
                transform = CGAffineTransformMakeRotation(M_PI/2.0f);
                break;
            default:
                break;
        }
    }
    else if (_startingInfo.startingInterfaceOrientation == UIInterfaceOrientationLandscapeRight) {
        switch ([UIApplication sharedApplication].statusBarOrientation) {
            case UIInterfaceOrientationLandscapeLeft:
                transform = CGAffineTransformMakeRotation(M_PI);
                break;
            case UIInterfaceOrientationLandscapeRight:
                transform = CGAffineTransformIdentity;
                break;
            case UIInterfaceOrientationPortrait:
                transform = CGAffineTransformMakeRotation(M_PI/2.0f);
                break;
            case UIInterfaceOrientationPortraitUpsideDown:
                transform = CGAffineTransformMakeRotation(-M_PI/2.0f);
                break;
            default:
                break;
        }
    }
    
    if (_flags.rotationTransformIsDirty) {
        _flags.rotationTransformIsDirty = NO;
        self.currentSnapshotRotationTransform = transform;
        if (_flags.isPresented) {
            self.scrollView.frame = self.view.bounds;
        }
    }
}

- (void)updateScrollViewAndImageViewForCurrentMetrics {
    
    if (_flags.isAnimatingAPresentationOrDismissal == NO) {
        _flags.isManuallyResizingTheScrollViewFrame = YES;
        self.scrollView.frame = self.view.bounds;
        _flags.isManuallyResizingTheScrollViewFrame = NO;
    }
    
    BOOL suppressAdjustments = _flags.isAnimatingAPresentationOrDismissal;
    
    if (suppressAdjustments == NO) {
        if (self.image) {
            self.imageView.frame = [self resizedFrameForAutorotatingImageView:self.image.size];
        } else {
            self.imageView.frame = [self resizedFrameForAutorotatingImageView:self.imageInfo.referenceRect.size];
        }
        self.scrollView.contentSize = self.imageView.frame.size;
        self.scrollView.contentInset = [self contentInsetForScrollView:self.scrollView.zoomScale];
    }
}

- (UIEdgeInsets)contentInsetForScrollView:(CGFloat)targetZoomScale {
    UIEdgeInsets inset = UIEdgeInsetsZero;
    CGFloat boundsHeight = self.scrollView.bounds.size.height;
    CGFloat boundsWidth = self.scrollView.bounds.size.width;
    CGFloat contentHeight = (self.image.size.height > 0) ? self.image.size.height : boundsHeight;
    CGFloat contentWidth = (self.image.size.width > 0) ? self.image.size.width : boundsWidth;
    CGFloat minContentHeight;
    CGFloat minContentWidth;
    if (contentHeight > contentWidth) {
        if (boundsHeight/boundsWidth < contentHeight/contentWidth) {
            minContentHeight = boundsHeight - (_imageInfo.edgePadding * 2);
            minContentWidth = contentWidth * (minContentHeight / contentHeight);
        } else {
            minContentWidth = boundsWidth - (_imageInfo.edgePadding * 2);
            minContentHeight = contentHeight * (minContentWidth / contentWidth);
        }
    } else {
        if (boundsWidth/boundsHeight < contentWidth/contentHeight) {
            minContentWidth = boundsWidth - (_imageInfo.edgePadding * 2);
            minContentHeight = contentHeight * (minContentWidth / contentWidth);
        } else {
            minContentHeight = boundsHeight - (_imageInfo.edgePadding * 2);
            minContentWidth = contentWidth * (minContentHeight / contentHeight);
        }
    }
    CGFloat myHeight = self.view.bounds.size.height;
    CGFloat myWidth = self.view.bounds.size.width;
    minContentWidth *= targetZoomScale;
    minContentHeight *= targetZoomScale;
    if (minContentHeight > myHeight && minContentWidth > myWidth) {
        inset = UIEdgeInsetsZero;
    } else {
        CGFloat verticalDiff = boundsHeight - minContentHeight;
        CGFloat horizontalDiff = boundsWidth - minContentWidth;
        verticalDiff = (verticalDiff > 0) ? verticalDiff : 0;
        horizontalDiff = (horizontalDiff > 0) ? horizontalDiff : 0;
        inset.top = verticalDiff/2.0f;
        inset.bottom = verticalDiff/2.0f;
        inset.left = horizontalDiff/2.0f;
        inset.right = horizontalDiff/2.0f;
    }
    return inset;
}

- (CGRect)resizedFrameForAutorotatingImageView:(CGSize)imageSize {
    CGRect frame = self.view.bounds;
    CGFloat screenWidth = frame.size.width - (_imageInfo.edgePadding * 2) * self.scrollView.zoomScale;
    CGFloat screenHeight = frame.size.height - (_imageInfo.edgePadding * 2) * self.scrollView.zoomScale;
    CGFloat targetWidth = screenWidth;
    CGFloat targetHeight = screenHeight;
    CGFloat nativeHeight = screenHeight;
    CGFloat nativeWidth = screenWidth;
    if (imageSize.width > 0 && imageSize.height > 0) {
        nativeHeight = (imageSize.height > 0) ? imageSize.height : screenHeight;
        nativeWidth = (imageSize.width > 0) ? imageSize.width : screenWidth;
    }
    if (nativeHeight > nativeWidth) {
        if (screenHeight/screenWidth < nativeHeight/nativeWidth) {
            targetWidth = screenHeight / (nativeHeight / nativeWidth);
        } else {
            targetHeight = screenWidth / (nativeWidth / nativeHeight);
        }
    } else {
        if (screenWidth/screenHeight < nativeWidth/nativeHeight) {
            targetHeight = screenWidth / (nativeWidth / nativeHeight);
        } else {
            targetWidth = screenHeight / (nativeHeight / nativeWidth);
        }
    }
    frame.size = CGSizeMake(targetWidth, targetHeight);
    frame.origin = CGPointMake(0, 0);
    return frame;
}

#pragma mark - UIScrollViewDelegate

- (UIView *)viewForZoomingInScrollView:(UIScrollView *)scrollView {
    return self.imageView;
}

- (void)scrollViewDidZoom:(UIScrollView *)scrollView {
    
    if (_flags.imageIsFlickingAwayForDismissal) {
        return;
    }
    
    scrollView.contentInset = [self contentInsetForScrollView:scrollView.zoomScale];
    
    if (self.scrollView.scrollEnabled == NO) {
        self.scrollView.scrollEnabled = YES;
    }
    
    if (_flags.isAnimatingAPresentationOrDismissal == NO && _flags.isManuallyResizingTheScrollViewFrame == NO) {
        [self updateDimmingViewForCurrentZoomScale:YES];
    }
}

- (void)scrollViewDidEndZooming:(UIScrollView *)scrollView withView:(UIView *)view atScale:(CGFloat)scale {
    
    if (_flags.imageIsFlickingAwayForDismissal) {
        return;
    }
    
    self.scrollView.scrollEnabled = (scale > 1);
    self.scrollView.contentInset = [self contentInsetForScrollView:scale];
}

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate {
    
    if (_flags.imageIsFlickingAwayForDismissal) {
        return;
    }
    
    CGPoint velocity = [scrollView.panGestureRecognizer velocityInView:scrollView.panGestureRecognizer.view];
    if (scrollView.zoomScale == 1 && (JTSImageFloatAbs(velocity.x) > 1600 || JTSImageFloatAbs(velocity.y) > 1600 ) ) {
        [self dismiss:YES];
    }
}

#pragma mark - Update Dimming View for Zoom Scale

- (void)updateDimmingViewForCurrentZoomScale:(BOOL)animated {
    CGFloat zoomScale = self.scrollView.zoomScale;
    CGFloat targetAlpha = (zoomScale > 1) ? 1.0f : self.alphaForBackgroundDimmingOverlay;
    CGFloat duration = (animated) ? 0.35 : 0;
    [UIView animateWithDuration:duration delay:0 options:UIViewAnimationOptionCurveLinear | UIViewAnimationOptionBeginFromCurrentState animations:^{
        self.blackBackdrop.alpha = targetAlpha;
    } completion:nil];
}

#pragma mark - Gesture Recognizer Actions

- (void)imageDoubleTapped:(UITapGestureRecognizer *)sender {
    
    if (_flags.scrollViewIsAnimatingAZoom) {
        return;
    }
    
    CGPoint rawLocation = [sender locationInView:sender.view];
    CGPoint point = [self.scrollView convertPoint:rawLocation fromView:sender.view];
    CGRect targetZoomRect;
    UIEdgeInsets targetInsets;
    if (self.scrollView.zoomScale == 1.0f) {
        self.scrollView.accessibilityHint = self.accessibilityHintZoomedIn;
        CGFloat zoomWidth = self.view.bounds.size.width / JTSImageViewController_TargetZoomForDoubleTap;
        CGFloat zoomHeight = self.view.bounds.size.height / JTSImageViewController_TargetZoomForDoubleTap;
        targetZoomRect = CGRectMake(point.x - (zoomWidth/2.0f), point.y - (zoomHeight/2.0f), zoomWidth, zoomHeight);
        targetInsets = [self contentInsetForScrollView:JTSImageViewController_TargetZoomForDoubleTap];
    } else {
        self.scrollView.accessibilityHint = self.accessibilityHintZoomedOut;
        CGFloat zoomWidth = self.view.bounds.size.width * self.scrollView.zoomScale;
        CGFloat zoomHeight = self.view.bounds.size.height * self.scrollView.zoomScale;
        targetZoomRect = CGRectMake(point.x - (zoomWidth/2.0f), point.y - (zoomHeight/2.0f), zoomWidth, zoomHeight);
        targetInsets = [self contentInsetForScrollView:1.0f];
    }
    self.view.userInteractionEnabled = NO;
    
    [CATransaction begin];
    __weak JTSImageViewController *weakSelf = self;
    [CATransaction setCompletionBlock:^{
        weakSelf.scrollView.contentInset = targetInsets;
        weakSelf.view.userInteractionEnabled = YES;
        _flags.scrollViewIsAnimatingAZoom = NO;
    }];
    [self.scrollView zoomToRect:targetZoomRect animated:YES];
    [CATransaction commit];
}

- (void)imageSingleTapped:(id)sender {
    if (_flags.scrollViewIsAnimatingAZoom) {
        return;
    }
    [self dismiss:YES];
}

- (void)dismissingPanGestureRecognizerPanned:(UIPanGestureRecognizer *)panner {
    
    if (_flags.scrollViewIsAnimatingAZoom || _flags.isAnimatingAPresentationOrDismissal) {
        return;
    }
    
    CGPoint translation = [panner translationInView:panner.view];
    CGPoint locationInView = [panner locationInView:panner.view];
    CGPoint velocity = [panner velocityInView:panner.view];
    CGFloat vectorDistance = sqrtf(powf(velocity.x, 2)+powf(velocity.y, 2));
    
    if (panner.state == UIGestureRecognizerStateBegan) {
        _flags.isDraggingImage = CGRectContainsPoint(self.imageView.frame, locationInView);
        if (_flags.isDraggingImage) {
            [self startImageDragging:locationInView translationOffset:UIOffsetZero];
        }
    }
    else if (panner.state == UIGestureRecognizerStateChanged) {
        if (_flags.isDraggingImage) {
            CGPoint newAnchor = self.imageDragStartingPoint;
            newAnchor.x += translation.x + self.imageDragOffsetFromActualTranslation.horizontal;
            newAnchor.y += translation.y + self.imageDragOffsetFromActualTranslation.vertical;
            self.attachmentBehavior.anchorPoint = newAnchor;
        } else {
            _flags.isDraggingImage = CGRectContainsPoint(self.imageView.frame, locationInView);
            if (_flags.isDraggingImage) {
                UIOffset translationOffset = UIOffsetMake(-1*translation.x, -1*translation.y);
                [self startImageDragging:locationInView translationOffset:translationOffset];
            }
        }
    }
    else {
        if (vectorDistance > JTSImageViewController_MinimumFlickDismissalVelocity) {
            if (_flags.isDraggingImage) {
                [self dismissImageWithFlick:velocity];
            } else {
                [self dismiss:YES];
            }
        }
        else {
            [self cancelCurrentImageDrag:YES];
        }
    }
}

#pragma mark - Dynamic Image Dragging

- (void)startImageDragging:(CGPoint)panGestureLocationInView translationOffset:(UIOffset)translationOffset {
    self.imageDragStartingPoint = panGestureLocationInView;
    self.imageDragOffsetFromActualTranslation = translationOffset;
    CGPoint anchor = self.imageDragStartingPoint;
    CGPoint imageCenter = self.imageView.center;
    UIOffset offset = UIOffsetMake(panGestureLocationInView.x-imageCenter.x, panGestureLocationInView.y-imageCenter.y);
    self.imageDragOffsetFromImageCenter = offset;
    self.attachmentBehavior = [[UIAttachmentBehavior alloc] initWithItem:self.imageView offsetFromCenter:offset attachedToAnchor:anchor];
    [self.animator addBehavior:self.attachmentBehavior];
    UIDynamicItemBehavior *modifier = [[UIDynamicItemBehavior alloc] initWithItems:@[self.imageView]];
    modifier.angularResistance = [self appropriateAngularResistanceForView:self.imageView];
    modifier.density = [self appropriateDensityForView:self.imageView];
    [self.animator addBehavior:modifier];
}

- (void)cancelCurrentImageDrag:(BOOL)animated {
    [self.animator removeAllBehaviors];
    self.attachmentBehavior = nil;
    _flags.isDraggingImage = NO;
    if (animated == NO) {
        self.imageView.transform = CGAffineTransformIdentity;
        self.imageView.center = CGPointMake(self.scrollView.contentSize.width/2.0f, self.scrollView.contentSize.height/2.0f);
    } else {
        [UIView
         animateWithDuration:0.7
         delay:0
         usingSpringWithDamping:0.7
         initialSpringVelocity:0
         options:UIViewAnimationOptionAllowUserInteraction |
         UIViewAnimationOptionBeginFromCurrentState
         animations:^{
             if (_flags.isDraggingImage == NO) {
                 self.imageView.transform = CGAffineTransformIdentity;
                 if (self.scrollView.dragging == NO && self.scrollView.decelerating == NO) {
                     self.imageView.center = CGPointMake(self.scrollView.contentSize.width/2.0f, self.scrollView.contentSize.height/2.0f);
                     [self updateScrollViewAndImageViewForCurrentMetrics];
                 }
             }
         } completion:nil];
    }
}

- (void)dismissImageWithFlick:(CGPoint)velocity {
    _flags.imageIsFlickingAwayForDismissal = YES;
    __weak JTSImageViewController *weakSelf = self;
    UIPushBehavior *push = [[UIPushBehavior alloc] initWithItems:@[self.imageView] mode:UIPushBehaviorModeInstantaneous];
    push.pushDirection = CGVectorMake(velocity.x*0.1, velocity.y*0.1);
    [push setTargetOffsetFromCenter:self.imageDragOffsetFromImageCenter forItem:self.imageView];
    push.action = ^{
        if ([weakSelf imageViewIsOffscreen]) {
            [weakSelf.animator removeAllBehaviors];
            weakSelf.attachmentBehavior = nil;
            [weakSelf.imageView removeFromSuperview];
            [weakSelf dismiss:YES];
        }
    };
    [self.animator removeBehavior:self.attachmentBehavior];
    [self.animator addBehavior:push];
}

- (CGFloat)appropriateAngularResistanceForView:(UIView *)view {
    CGFloat height = view.bounds.size.height;
    CGFloat width = view.bounds.size.width;
    CGFloat actualArea = height * width;
    CGFloat referenceArea = self.view.bounds.size.width * self.view.bounds.size.height;
    CGFloat factor = referenceArea / actualArea;
    CGFloat defaultResistance = 4.0f; // Feels good with a 1x1 on 3.5 inch displays. We'll adjust this to match the current display.
    CGFloat screenWidth = [UIScreen mainScreen].bounds.size.width;
    CGFloat screenHeight = [UIScreen mainScreen].bounds.size.height;
    CGFloat resistance = defaultResistance * ((320.0 * 480.0) / (screenWidth * screenHeight));
    return resistance * factor;
}

- (CGFloat)appropriateDensityForView:(UIView *)view {
    CGFloat height = view.bounds.size.height;
    CGFloat width = view.bounds.size.width;
    CGFloat actualArea = height * width;
    CGFloat referenceArea = self.view.bounds.size.width * self.view.bounds.size.height;
    CGFloat factor = referenceArea / actualArea;
    CGFloat defaultDensity = 0.5f; // Feels good on 3.5 inch displays. We'll adjust this to match the current display.
    CGFloat screenWidth = [UIScreen mainScreen].bounds.size.width;
    CGFloat screenHeight = [UIScreen mainScreen].bounds.size.height;
    CGFloat appropriateDensity = defaultDensity * ((320.0 * 480.0) / (screenWidth * screenHeight));
    return appropriateDensity * factor;
}

- (BOOL)imageViewIsOffscreen {
    CGRect visibleRect = [self.scrollView convertRect:self.view.bounds fromView:self.view];
    return ([self.animator itemsInRect:visibleRect].count == 0);
}

- (CGPoint)targetDismissalPoint:(CGPoint)startingCenter velocity:(CGPoint)velocity {
    return CGPointMake(startingCenter.x + velocity.x/3.0 , startingCenter.y + velocity.y/3.0);
}

#pragma mark - Gesture Recognizer Delegate

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    
    BOOL shouldReceiveTouch = YES;
    
    if (shouldReceiveTouch && gestureRecognizer == self.panRecognizer) {
        shouldReceiveTouch = (self.scrollView.zoomScale == 1 && _flags.scrollViewIsAnimatingAZoom == NO);
    }
    
    return shouldReceiveTouch;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRequireFailureOfGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return (gestureRecognizer == self.singleTapperText);
}

#pragma mark - Progress Bar

- (void)startProgressTimer {
    self.downloadProgressTimer = [[NSTimer alloc] initWithFireDate:[NSDate date]
                                                          interval:0.05
                                                            target:self
                                                          selector:@selector(progressTimerFired:)
                                                          userInfo:nil
                                                           repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.downloadProgressTimer forMode:NSRunLoopCommonModes];
}

- (void)cancelProgressTimer {
    [self.downloadProgressTimer invalidate];
    self.downloadProgressTimer = nil;
}

- (void)progressTimerFired:(NSTimer *)timer {
    CGFloat progress = 0;
    CGFloat bytesExpected = self.imageDownloadDataTask.countOfBytesExpectedToReceive;
    if (bytesExpected > 0 && _flags.imageIsBeingReadFromDisk == NO) {
        [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveLinear animations:^{
            self.spinner.alpha = 0;
            self.progressView.alpha = 1;
        } completion:nil];
        progress = self.imageDownloadDataTask.countOfBytesReceived / bytesExpected;
    }
    self.progressView.progress = progress;
}

#pragma mark - Accessibility

- (NSString *)accessibilityHintZoomedOut {
    
    return @"\
    Image is zoomed out. \
    Pinch or Double tap the image to zoom in. \
    Tap to dismiss.";
}

- (NSString *)accessibilityHintZoomedIn {
    
    return @"\
    Image is zoomed in. \
    Pan around the image by dragging. \
    Pinch to adjust zoom \
    Tap to dismiss.";
}

- (NSString *)defaultAccessibilityLabelForScrollView {
    
    return @"Full-Screen Image Viewer";
}

@end



