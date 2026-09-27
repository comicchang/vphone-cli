// MARK: - viewfinder stream injection
//
// Camera.app's preview path goes through FigCameraViewfinderStream, NOT
// BWImageQueueSinkNode. The stream exposes -enqueueVideoSampleBuffer: which
// the daemon's normal frame producer calls to deliver each frame to the
// client (Camera.app's AVCaptureVideoPreviewLayer). For our synth source —
// which has no real producer — we hook -[FigCameraViewfinderStream init],
// capture each instance, and drive enqueueVideoSampleBuffer: ourselves on
// a 30 Hz timer, wrapping vcc_latest_frame pixels in a fresh CMSampleBuffer.

// Forward declaration — full definition is later in the file under the
// "shared-frame reader" section.
typedef struct vcc_latest_frame_s {
  pthread_mutex_t lock;
  uint32_t width;
  uint32_t height;
  uint32_t bytes_per_row;
  uint32_t pixel_format;
  uint64_t timestamp_ns;
  uint64_t frame_index;
  uint8_t *pixels;
  size_t   pixels_capacity;
  size_t   pixels_length;
} vcc_latest_frame_t;
extern vcc_latest_frame_t vcc_latest_frame;

static IMP vcc_vfs_init_orig = NULL;
static IMP vcc_vfs_open_orig = NULL;
static IMP vcc_vfs_close_orig = NULL;
static NSMutableArray *vcc_vf_streams = nil;  // strong refs
static dispatch_source_t vcc_vf_timer = NULL;
static dispatch_queue_t vcc_vf_q = NULL;
static uint64_t vcc_vf_enqueue_count = 0;
static uint64_t vcc_vf_enqueue_success = 0;
static uint64_t vcc_sink_drive_count = 0;
static uint64_t vcc_sink_drive_ok = 0;

static CMSampleBufferRef vcc_build_cmsb_from_shm_fmt(uint32_t fmt_out);

// Deliver the latest shm frame to every captured video sink — the
// client-graph tail. Driving them with our samples is what delivers frames
// to third-party AVCaptureVideoDataOutput clients, the same way the
// still-sink drive delivers photos. Runs on the same 30 Hz queue as the
// viewfinder drive. Graph-built sinks expect the active advertised format's
// samples — BGRA is what clients see selected (camfix substitutes the first
// format for third-party sessions).
static void vcc_drive_sinks_once(void) {
  NSArray *sinks = vcc_driven_sinks_snapshot();
  if (sinks.count == 0) return;
  CMSampleBufferRef cmsb = vcc_build_cmsb_from_shm_fmt(VCC_FMT_BGRA);
  if (!cmsb) return;
  SEL sel = @selector(renderSampleBuffer:forInput:);
  for (id sink in sinks) {
    if (![sink respondsToSelector:sel]) continue;
    @try {
      ((void (*)(id, SEL, CMSampleBufferRef, id))objc_msgSend)(
          sink, sel, cmsb, nil);
      vcc_sink_drive_ok++;
    } @catch (NSException *e) {
      if ((vcc_sink_drive_count & 63) == 1) {
        vcc_log(@"  [SINK drive] exception on %p: %@", sink, e);
      }
    }
  }
  CFRelease(cmsb);
  vcc_sink_drive_count++;
  if ((vcc_sink_drive_count & 59) == 1) {
    vcc_log(@"  [SINK drive] frames=%llu sinks=%lu ok=%llu",
            (unsigned long long)vcc_sink_drive_count,
            (unsigned long)sinks.count,
            (unsigned long long)vcc_sink_drive_ok);
  }
}

typedef id (*VccVfsInitFn)(id self, SEL _cmd);
typedef void (*VccVfsOpenFn)(id self, SEL _cmd, id dest);
typedef void (*VccVfsCloseFn)(id self, SEL _cmd);

static _Atomic uint64_t vcc_vfs_init_count = 0;

static id vcc_vfs_init_hook(id self, SEL _cmd) {
  VccVfsInitFn orig = (VccVfsInitFn)vcc_vfs_init_orig;
  id ret = orig(self, _cmd);
  // Throttled — Camera.app spins ~2000 inits/sec without ever opening
  // (session config silently incomplete). Log every 1024th to keep the log
  // file usable.
  uint64_t n = atomic_fetch_add(&vcc_vfs_init_count, 1) + 1;
  if ((n & 0x3ff) == 1) {
    vcc_log(@"  [VFS init] -> %p (total=%llu)",
            ret, (unsigned long long)n);
  }
  return ret;
}

static void vcc_vfs_open_hook(id self, SEL _cmd, id dest) {
  vcc_log(@"  [VFS open] self=%p dest=%@", self, dest);
  VccVfsOpenFn orig = (VccVfsOpenFn)vcc_vfs_open_orig;
  orig(self, _cmd, dest);
  if (!vcc_vf_streams) vcc_vf_streams = [NSMutableArray array];
  [vcc_vf_streams addObject:self];
  vcc_log(@"  [VFS open] captured stream %p (total=%lu)",
          self, (unsigned long)vcc_vf_streams.count);
}

static void vcc_vfs_close_hook(id self, SEL _cmd) {
  vcc_log(@"  [VFS close] self=%p", self);
  if (vcc_vf_streams) [vcc_vf_streams removeObject:self];
  VccVfsCloseFn orig = (VccVfsCloseFn)vcc_vfs_close_orig;
  orig(self, _cmd);
}

// Build a CMSampleBuffer wrapping the latest shm frame, in the requested
// delivery format. The heavy lifting (pixel-format-honest CVPixelBuffer,
// extension-bearing format description, camera attachments, host-frame
// timing) lives in the shared data plane, which Tests/VCamDataPlaneTests.c
// proves on the host. Caller must CFRelease.
//
// Serializes builds because the shared timing state advances per buffer and
// the viewfinder drive queue and the still-image drive run on different
// threads.
static pthread_mutex_t vcc_delivery_lock = PTHREAD_MUTEX_INITIALIZER;
static vcc_timing_state_t vcc_delivery_timing;
static pthread_once_t vcc_delivery_timing_once = PTHREAD_ONCE_INIT;

static void vcc_delivery_timing_init(void) {
  vcc_timing_init(&vcc_delivery_timing);
}

static CMSampleBufferRef vcc_build_cmsb_from_shm_fmt(uint32_t fmt_out) {
  pthread_mutex_lock(&vcc_delivery_lock);
  pthread_once(&vcc_delivery_timing_once, vcc_delivery_timing_init);

  vcc_frame_desc_t frame;
  memset(&frame, 0, sizeof(frame));
  uint8_t *pixels = NULL;
  pthread_mutex_lock(&vcc_latest_frame.lock);
  size_t len = vcc_latest_frame.pixels_length;
  if (len && vcc_latest_frame.width && vcc_latest_frame.height &&
      vcc_latest_frame.bytes_per_row) {
    pixels = malloc(len);
    if (pixels) memcpy(pixels, vcc_latest_frame.pixels, len);
  }
  if (pixels) {
    frame.width = vcc_latest_frame.width;
    frame.height = vcc_latest_frame.height;
    frame.bytes_per_row = vcc_latest_frame.bytes_per_row;
    frame.pixel_format = vcc_latest_frame.pixel_format;
    frame.timestamp_ns = vcc_latest_frame.timestamp_ns;
    frame.frame_index = vcc_latest_frame.frame_index;
    frame.pixels = pixels;
    frame.pixels_length = len;
  }
  pthread_mutex_unlock(&vcc_latest_frame.lock);

  if (!pixels) {
    pthread_mutex_unlock(&vcc_delivery_lock);
    return NULL;
  }

  CMSampleBufferRef cmsb = vcc_cmsb_from_frame(&frame, fmt_out,
                                               &vcc_delivery_timing);
  free(pixels);
  pthread_mutex_unlock(&vcc_delivery_lock);
  return cmsb;
}

// Viewfinder/video delivery: the active advertised format. The synthetic
// source publishes 420v as DefaultActiveFormat, so that's what AVF clients
// pick — the delivered sample must be the same thing, not a BGRA buffer
// wearing a 420v costume.
static CMSampleBufferRef vcc_build_cmsb_from_shm(void) {
  return vcc_build_cmsb_from_shm_fmt(VCC_FMT_420V);
}

static void vcc_vf_drive_once(void) {
  if (!vcc_vf_streams || vcc_vf_streams.count == 0) return;
  CMSampleBufferRef cmsb = vcc_build_cmsb_from_shm();
  if (!cmsb) return;
  SEL sel = NSSelectorFromString(@"enqueueVideoSampleBuffer:");
  for (id stream in [vcc_vf_streams copy]) {
    int ret = ((int (*)(id, SEL, CMSampleBufferRef))objc_msgSend)(
        stream, sel, cmsb);
    vcc_vf_enqueue_count++;
    if (ret == 0) vcc_vf_enqueue_success++;
    if ((vcc_vf_enqueue_count & 29) == 1) {
      vcc_log(@"  [VFS drive] enqueue ret=%d (count=%llu ok=%llu)",
              ret,
              (unsigned long long)vcc_vf_enqueue_count,
              (unsigned long long)vcc_vf_enqueue_success);
    }
  }
  CFRelease(cmsb);
}

static void vcc_install_viewfinder_hooks(void) {
  Class cls = NSClassFromString(@"FigCameraViewfinderStream");
  if (!cls) {
    vcc_log(@"  VF hook: class missing");
    return;
  }
  SEL init_sel = NSSelectorFromString(@"init");
  SEL open_sel = NSSelectorFromString(@"openWithDestination:");
  SEL close_sel = NSSelectorFromString(@"close");
  Method m;
  if ((m = class_getInstanceMethod(cls, init_sel))) {
    vcc_vfs_init_orig = method_setImplementation(m, (IMP)vcc_vfs_init_hook);
  }
  if ((m = class_getInstanceMethod(cls, open_sel))) {
    vcc_vfs_open_orig = method_setImplementation(m, (IMP)vcc_vfs_open_hook);
  }
  if ((m = class_getInstanceMethod(cls, close_sel))) {
    vcc_vfs_close_orig = method_setImplementation(m, (IMP)vcc_vfs_close_hook);
  }
  vcc_log(@"  swizzled FigCameraViewfinderStream init/open/close");

  // Drive at 30 Hz. Frames are enqueued only when at least one stream is
  // open AND a fresh shm frame exists (covered by build_cmsb_from_shm).
  vcc_vf_q = dispatch_queue_create("com.vphone.vcam.vfdrive",
                                     DISPATCH_QUEUE_SERIAL);
  vcc_vf_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                          vcc_vf_q);
  dispatch_source_set_timer(vcc_vf_timer,
                            dispatch_time(DISPATCH_TIME_NOW, 0),
                            33333333ull, 2000000ull);
  dispatch_source_set_event_handler(vcc_vf_timer, ^{
    @autoreleasepool {
      vcc_vf_drive_once();
      vcc_drive_sinks_once();
    }
  });
  dispatch_resume(vcc_vf_timer);
  vcc_log(@"  viewfinder drive timer armed (30 Hz, delivering '420v' "
          @"+ camera metadata)");
}

static void vcc_install_sink_observation(void) {
  Class iqsn = NSClassFromString(@"BWImageQueueSinkNode");
  Class rqsn = NSClassFromString(@"BWRemoteQueueSinkNode");
  if (!iqsn || !rqsn) {
    vcc_log(@"  sink obs: classes missing iqsn=%p rqsn=%p", iqsn, rqsn);
    return;
  }

  SEL iqsnInit = NSSelectorFromString(
      @"initWithHFRSupport:ispJitterCompensationEnabled:"
      @"clientAuditToken:sinkID:");
  SEL rqsnInit = NSSelectorFromString(
      @"initWithMediaType:clientAuditToken:sinkID:cameraInfoByPortType:");
  SEL renderSel = @selector(renderSampleBuffer:forInput:);

  vcc_swizzle_method(iqsn, iqsnInit, (IMP)vcc_iqsn_init_hook,
                      &vcc_iqsn_init_orig);
  vcc_swizzle_method(rqsn, rqsnInit, (IMP)vcc_rqsn_init_hook,
                      &vcc_rqsn_init_orig);
  vcc_swizzle_method(iqsn, renderSel, (IMP)vcc_iqsn_render_hook,
                      &vcc_iqsn_render_orig);
  vcc_swizzle_method(rqsn, renderSel, (IMP)vcc_rqsn_render_hook,
                      &vcc_rqsn_render_orig);
}
