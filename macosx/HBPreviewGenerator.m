/*  HBPreviewGenerator.m $

 This file is part of the HandBrake source code.
 Homepage: <http://handbrake.fr/>.
 It may be used under the terms of the GNU General Public License. */
//

#import "HBPreviewGenerator.h"
#import "Controller.h"

typedef enum EncodeState : NSUInteger {
    EncodeStateIdle,
    EncodeStateWorking,
    EncodeStateCancelled,
} EncodeState;

@interface HBPreviewGenerator ()

@property (nonatomic, readonly, retain) NSMutableDictionary *picturePreviews;
@property (nonatomic, readonly) NSUInteger imagesCount;
@property (nonatomic, readonly) hb_handle_t *handle;
@property (nonatomic, readonly) hb_title_t *title;

@property (nonatomic) hb_handle_t *privateHandle;
@property (nonatomic) NSTimer *timer;
@property (nonatomic) EncodeState encodeState;

@property (nonatomic, retain) NSURL *fileURL;

@end

@implementation HBPreviewGenerator

- (id) initWithHandle: (hb_handle_t *) handle andTitle: (hb_title_t *) title
{
    self = [super init];
    if (self)
    {
        _handle = handle;
        _title = title;
        _picturePreviews = [[NSMutableDictionary alloc] init];
        _imagesCount = [[[NSUserDefaults standardUserDefaults] objectForKey:@"PreviewsNumber"] intValue];
    }
    return self;
}

#pragma mark -
#pragma mark Preview images

/**
 * Returns the picture preview at the specified index
 *
 * @param index picture index in title.
 */
- (NSImage *) imageAtIndex: (NSUInteger) index
{
    if (index >= self.imagesCount)
        return nil;

    // The preview for the specified index may not currently exist, so this method
    // generates it if necessary.
    NSImage *theImage = [self.picturePreviews objectForKey:@(index)];

    if (!theImage)
    {
        theImage = [HBPreviewGenerator makeImageForPicture:index
                                                     libhb:self.handle
                                                     title:self.title
                                               deinterlace:self.deinterlace];
        [self.picturePreviews setObject:theImage forKey:@(index)];
    }

    return theImage;
}

/**
 * Purges all images from the cache. The next call to imageAtIndex: will cause a new
 * image to be generated.
 */
- (void) purgeImageCache
{
    [self.picturePreviews removeAllObjects];
}

/** 
 * This function converts an image created by libhb (specified via pictureIndex) into
 * an NSImage suitable for the GUI code to use. If removeBorders is YES,
 * makeImageForPicture crops the image generated by libhb stripping off the gray
 * border around the content. This is the low-level method that generates the image.
 * -imageForPicture calls this function whenever it can't find an image in its cache.
 *
 * @param picture Index in title.
 * @param h Handle to hb_handle_t.
 * @param title Handle to hb_title_t of desired title.
 */
+ (NSImage *) makeImageForPicture: (NSUInteger) pictureIndex
                            libhb: (hb_handle_t *) handle
                            title: (hb_title_t *) title
                      deinterlace: (BOOL) deinterlace
{
    static uint8_t *buffer;
    static int bufferSize;

    // Make sure we have a big enough buffer to receive the image from libhb
    int dstWidth = title->job->width;
    int dstHeight = title->job->height;

    int newSize = dstWidth * dstHeight * 4;
    if  (!buffer || bufferSize < newSize)
    {
        bufferSize = newSize;
        buffer     = (uint8_t *) realloc( buffer, bufferSize );
    }

    // Enable and the disable deinterlace just for preview if deinterlace
    // or decomb filters are enabled
    int deinterlaceStatus = title->job->deinterlace;
    if (deinterlace) title->job->deinterlace = 1;

    hb_get_preview( handle, title->job, (int)pictureIndex, buffer );

    // Reset deinterlace status
    title->job->deinterlace = deinterlaceStatus;

    // Create an NSBitmapImageRep and copy the libhb image into it, converting it from
    // libhb's format to one suitable for NSImage. Along the way, we'll strip off the
    // border around libhb's image.

    // The image data returned by hb_get_preview is 4 bytes per pixel, BGRA format.
    // Alpha is ignored.

    NSBitmapFormat bitmapFormat = (NSBitmapFormat)NSAlphaFirstBitmapFormat;
    NSBitmapImageRep * imgrep = [[[NSBitmapImageRep alloc]
                                  initWithBitmapDataPlanes:nil
                                  pixelsWide:dstWidth
                                  pixelsHigh:dstHeight
                                  bitsPerSample:8
                                  samplesPerPixel:3   // ignore alpha
                                  hasAlpha:NO
                                  isPlanar:NO
                                  colorSpaceName:NSCalibratedRGBColorSpace
                                  bitmapFormat:bitmapFormat
                                  bytesPerRow:dstWidth * 4
                                  bitsPerPixel:32] autorelease];

    UInt32 * src = (UInt32 *)buffer;
    UInt32 * dst = (UInt32 *)[imgrep bitmapData];
    int r, c;
    for (r = 0; r < dstHeight; r++)
    {
        for (c = 0; c < dstWidth; c++)
#if TARGET_RT_LITTLE_ENDIAN
            *dst++ = Endian32_Swap(*src++);
#else
            *dst++ = *src++;
#endif
    }

    NSImage * img = [[[NSImage alloc] initWithSize: NSMakeSize(dstWidth, dstHeight)] autorelease];
    [img addRepresentation:imgrep];

    return img;
}

#pragma mark -
#pragma mark Preview movie

+ (NSString *) appSupportPath
{
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *appSupportPath = nil;

    NSArray *allPaths = NSSearchPathForDirectoriesInDomains( NSApplicationSupportDirectory,
                                                            NSUserDomainMask,
                                                            YES );
    if ([allPaths count])
        appSupportPath = [[allPaths objectAtIndex:0] stringByAppendingPathComponent:@"HandBrake"];

    if (![fileManager fileExistsAtPath:appSupportPath])
        [fileManager createDirectoryAtPath:appSupportPath withIntermediateDirectories:YES attributes:nil error:NULL];

    return appSupportPath;
}

+ (NSURL *) generateFileURLForType:(NSString *) type
{
    NSString *previewDirectory = [NSString stringWithFormat:@"%@/Previews/%d", [HBPreviewGenerator appSupportPath], getpid()];

    if (![[NSFileManager defaultManager] fileExistsAtPath:previewDirectory])
    {
        if (![[NSFileManager defaultManager] createDirectoryAtPath:previewDirectory
                                  withIntermediateDirectories:NO
                                                   attributes:nil
                                                        error:nil])
            return nil;
    }

    return [[NSURL fileURLWithPath:previewDirectory]
            URLByAppendingPathComponent:[NSString stringWithFormat:@"preview_temp.%@", type]];
}

/**
 * This function start the encode of a movie preview, the delegate will be
 * called with the updated the progress info and the fileURL.
 * The called must call HBController prepareJobForPreview before this.
 *
 * @param index picture index in title.
 * @param duration the duration in seconds of the preview movie.
 */
- (BOOL) createMovieAsyncWithImageIndex: (NSUInteger) index andDuration: (NSUInteger) duration;
{
    /* return if an encoding if already started */
    if (self.encodeState || index >= self.imagesCount)
        return NO;

    hb_job_t *job = self.title->job;

    /* Generate the file url and directories. */
    if (job->mux & HB_MUX_MASK_MP4)
    {
        /* we use .m4v for our mp4 files so that ac3 and chapters in mp4 will play properly */
        self.fileURL = [HBPreviewGenerator generateFileURLForType:@"m4v"];
    }
    else if (job->mux & HB_MUX_MASK_MKV)
    {
        self.fileURL = [HBPreviewGenerator generateFileURLForType:@"mkv"];
    }

    /* return if we couldn't get the fileURL */
    if (!self.fileURL)
        return NO;

    /* See if there is an existing preview file, if so, delete it */
    if (![[NSFileManager defaultManager] fileExistsAtPath:[self.fileURL path]])
    {
        [[NSFileManager defaultManager] removeItemAtPath:[self.fileURL path] error:NULL];
    }

    /* We now direct our preview encode to fileURL path */
    hb_job_set_file(job, [[self.fileURL path] UTF8String]);

    /* We use our advance pref to determine how many previews to scan */
    job->start_at_preview = (int)index + 1;
    job->seek_points = (int)self.imagesCount;
    job->pts_to_stop = duration * 90000LL;

    /* lets go ahead and send it off to libhb
     * Note: unlike a full encode, we only send 1 pass regardless if the final encode calls for 2 passes.
     * this should suffice for a fairly accurate short preview and cuts our preview generation time in half.
     * However we also need to take into account the indepth scan for subtitles.
     */

    int loggingLevel = [[[NSUserDefaults standardUserDefaults] objectForKey:@"LoggingLevel"] intValue];
    self.privateHandle = hb_init(loggingLevel, 0);

    /* If scanning we need to do some extra setup of the job. */
    if (job->indepth_scan == 1)
    {
        char *x264opts_tmp;
        /* When subtitle scan is enabled do a fast pre-scan job
         * which will determine which subtitles to enable, if any. */
        job->pass = -1;
        x264opts_tmp = job->advanced_opts;

        job->advanced_opts = NULL;
        job->indepth_scan = 1;

        /* Add the pre-scan job */
        hb_add(self.privateHandle, job);
        job->advanced_opts = x264opts_tmp;
    }

    /* Go ahead and perform the actual encoding preview scan */
    job->indepth_scan = 0;
    job->pass = 0;

    hb_add(self.privateHandle, job);

    /* we need to clean up the various lists after the job(s) have been set  */
    hb_job_reset(job);

    /* start the actual encode */
    self.encodeState = EncodeStateWorking;
    hb_system_sleep_prevent(self.privateHandle);

    [self startHBTimer];

    hb_start(self.privateHandle);

    return YES;
}

/**
 * Cancels the encoding process
 */
- (void) cancel
{
    if (self.privateHandle)
    {
        hb_state_t s;
        hb_get_state2(self.privateHandle, &s);

        if (self.encodeState && (s.state == HB_STATE_WORKING ||
                                  s.state == HB_STATE_PAUSED))
        {
            self.encodeState = EncodeStateCancelled;
            hb_stop(self.privateHandle);
            hb_system_sleep_allow(self.privateHandle);
        }
    }
}

- (void) startHBTimer
{
    if (!self.timer)
    {
        self.timer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                      target:self
                                                    selector:@selector(updateState)
                                                    userInfo:nil
                                                     repeats:YES];
    }
}

- (void) stopHBTimer
{
    [self.timer invalidate];
    self.timer = nil;
}

- (void) updateState
{
    hb_state_t s;
    hb_get_state(self.privateHandle, &s);

    switch( s.state )
    {
        case HB_STATE_IDLE:
        case HB_STATE_SCANNING:
        case HB_STATE_SCANDONE:
            break;

        case HB_STATE_WORKING:
        {
			NSMutableString *info = [NSMutableString stringWithFormat: @"Encoding preview:  %.2f %%", 100.0 * s.param.working.progress];

			if( s.param.working.seconds > -1 )
            {
                [info appendFormat:@" (%.2f fps, avg %.2f fps, ETA %02dh%02dm%02ds)",
                 s.param.working.rate_cur, s.param.working.rate_avg, s.param.working.hours,
                 s.param.working.minutes, s.param.working.seconds];
            }

            double progress = 100.0 * s.param.working.progress;

            [self.delegate updateProgress:progress info:info];

            break;
        }

        case HB_STATE_MUXING:
        {
            NSString *info = @"Muxing Preview…";
            double progress = 100.0;

            [self.delegate updateProgress:progress info:info];

            break;
        }

        case HB_STATE_PAUSED:
            break;

        case HB_STATE_WORKDONE:
        {
            [self stopHBTimer];

            // Delete all remaining jobs since libhb doesn't do this on its own.
            hb_job_t * job;
            while( ( job = hb_job(self.privateHandle, 0) ) )
                hb_rem( self.handle, job );

            hb_system_sleep_allow(self.privateHandle);
            hb_stop(self.privateHandle);
            hb_close(&_privateHandle);
            self.privateHandle = NULL;

            /* Encode done, call the delegate and close libhb handle */
            if (self.encodeState != EncodeStateCancelled)
            {
                [self.delegate didCreateMovieAtURL:self.fileURL];
            }

            self.encodeState = EncodeStateIdle;

            break;
        }
    }
}

#pragma mark -

- (void) dealloc
{
    [_timer invalidate];
    [_timer release];
    _timer = nil;

    if (_privateHandle) {
        hb_system_sleep_allow(self.privateHandle);
        hb_stop(_privateHandle);
        hb_close(&_privateHandle);
    }

    [_fileURL release];
    _fileURL = nil;
    [_picturePreviews release];
    _picturePreviews = nil;

    [super dealloc];
}

@end
