/**
 * RTMPClient.m — RTMP stream puller using embedded librtmp.
 *
 * Flow:
 * 1. startWithRTMPURL: → spawn background thread
 * 2. _connectAndPullWithGeneration: → RTMP_SetupURL → Connect → ConnectStream
 * 3. _readLoop → RTMP_ReadPacket → filter video packets (type 0x09)
 * 4. _handleVideoPacket → parse AVCC → H264Decoder
 * 5. On disconnect → scheduleReconnect
 *
 * Requires librtmp to be compiled and linked.
 * Get source from: https://rtmpdump.mber.com/
 */

#import "RTMPClient.h"
#import "H264Decoder.h"
#import "../Shared/VcamConstants.h"

// librtmp C headers
#include "librtmp/rtmp.h"
#include "librtmp/log.h"

@interface RTMPClient ()
@property (nonatomic, strong) H264Decoder *decoder;
@property (nonatomic, copy) NSString *rtmpURL;
@property (nonatomic, assign) NSUInteger generation;
@property (nonatomic, assign) BOOL waitingForKeyframe;
@property (nonatomic, strong) dispatch_source_t reconnectTimer;
@end

@implementation RTMPClient {
    RTMP *_rtmp;
    dispatch_queue_t _rtmpQueue;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _rtmpQueue = dispatch_queue_create("com.lumiere.vcam.rtmp", DISPATCH_QUEUE_SERIAL);
        _decoder = [[H264Decoder alloc] init];
        _generation = 0;
        _waitingForKeyframe = YES;
    }
    return self;
}

- (void)dealloc {
    [self stop];
}

#pragma mark - Public

- (void)startWithRTMPURL:(NSString *)url {
    [self stop];

    self.rtmpURL = url;
    self.generation++;
    _isRunning = YES;

    NSUInteger gen = self.generation;
    VCLog(@"RTMPClient: starting with URL=%@ gen=%lu", url, (unsigned long)gen);

    dispatch_async(_rtmpQueue, ^{
        [self _connectAndPullWithGeneration:gen];
    });
}

- (void)stop {
    _isRunning = NO;
    self.generation++;

    [self _cancelReconnect];

    dispatch_async(_rtmpQueue, ^{
        [self _closeRTMP];
        [self.decoder invalidate];
    });

    VCLog(@"RTMPClient: stopped");
}

#pragma mark - Connection

- (void)_connectAndPullWithGeneration:(NSUInteger)gen {
    if (gen != self.generation || !_isRunning) return;

    self.waitingForKeyframe = YES;

    _rtmp = RTMP_Alloc();
    if (!_rtmp) {
        VCLog(@"RTMPClient: RTMP_Alloc failed");
        [self _scheduleReconnectWithDelay:kVCReconnectDelay1 generation:gen];
        return;
    }

    RTMP_Init(_rtmp);

    // Set URL
    const char *urlCStr = [self.rtmpURL UTF8String];
    if (!RTMP_SetupURL(_rtmp, (char *)urlCStr)) {
        VCLog(@"RTMPClient: RTMP_SetupURL failed for %@", self.rtmpURL);
        RTMP_Free(_rtmp); _rtmp = NULL;
        [self _scheduleReconnectWithDelay:kVCReconnectDelay1 generation:gen];
        return;
    }

    // Enable live stream mode
    _rtmp->Link.lFlags |= RTMP_LF_LIVE;

    // Connect
    VCLog(@"RTMPClient: connecting...");
    if (!RTMP_Connect(_rtmp, NULL)) {
        VCLog(@"RTMPClient: RTMP_Connect failed");
        RTMP_Close(_rtmp); RTMP_Free(_rtmp); _rtmp = NULL;
        [self _notifyError:@"RTMP connect failed"];
        [self _scheduleReconnectWithDelay:kVCReconnectDelay1 generation:gen];
        return;
    }

    VCLog(@"RTMPClient: connected, handshaking...");

    if (!RTMP_ConnectStream(_rtmp, 0)) {
        VCLog(@"RTMPClient: RTMP_ConnectStream failed");
        RTMP_Close(_rtmp); RTMP_Free(_rtmp); _rtmp = NULL;
        [self _notifyError:@"RTMP stream connect failed"];
        [self _scheduleReconnectWithDelay:kVCReconnectDelay1 generation:gen];
        return;
    }

    VCLog(@"RTMPClient: handshaked, stream connected!");
    _isConnected = YES;

    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self.delegate respondsToSelector:@selector(rtmpClientDidConnect:)]) {
            [self.delegate rtmpClientDidConnect:self];
        }
    });

    // Enter read loop
    [self _readLoopWithGeneration:gen];
}

#pragma mark - Read Loop

- (void)_readLoopWithGeneration:(NSUInteger)gen {
    RTMPPacket packet;
    memset(&packet, 0, sizeof(RTMPPacket));

    VCLog(@"RTMPClient: entering read loop");

    while (gen == self.generation && _isRunning && RTMP_IsConnected(_rtmp)) {
        int ret = RTMP_ReadPacket(_rtmp, &packet);
        if (!ret) {
            VCLog(@"RTMPClient: RTMP_ReadPacket returned 0 (disconnected)");
            break;
        }

        if (!RTMPPacket_IsReady(&packet)) continue;

        // Process the packet
        if (packet.m_packetType == RTMP_PACKET_TYPE_VIDEO) {
            [self _handleVideoPacket:(uint8_t *)packet.m_body
                              length:packet.m_nBodySize
                           timestamp:packet.m_nTimeStamp];
        }

        // Let librtmp handle invoke/control packets
        RTMP_ClientPacket(_rtmp, &packet);
        RTMPPacket_Free(&packet);
    }

    // Disconnected
    _isConnected = NO;
    [self _closeRTMP];

    VCLog(@"RTMPClient: read loop ended (gen=%lu)", (unsigned long)gen);

    if (gen == self.generation && _isRunning) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([self.delegate respondsToSelector:@selector(rtmpClientDidDisconnect:reason:)]) {
                [self.delegate rtmpClientDidDisconnect:self reason:@"connection_lost"];
            }
        });
        [self _scheduleReconnectWithDelay:kVCReconnectDelay2 generation:gen];
    }
}

#pragma mark - Video Packet Handling

- (void)_handleVideoPacket:(uint8_t *)data length:(uint32_t)length timestamp:(uint32_t)ts {
    if (length < 5) return;

    /*
     * FLV Video Tag format:
     * data[0]: frameType(4 bits) | codecID(4 bits)
     * data[1]: AVCPacketType (0=seq header, 1=NALU)
     * data[2..4]: composition time offset
     * data[5..]: payload
     */

    uint8_t frameType = (data[0] >> 4) & 0x0F;   // 1=keyframe, 2=interframe
    uint8_t codecID   = data[0] & 0x0F;           // 7=AVC (H264)
    uint8_t avcType   = data[1];                   // 0=sequence header, 1=NALU

    if (codecID != 7) {
        // Not H264, skip
        return;
    }

    if (avcType == 0) {
        // AVC Sequence Header → extract SPS/PPS
        [self _parseAVCSequenceHeader:data + 5 length:length - 5];
    } else if (avcType == 1) {
        // AVC NALU
        BOOL isKeyframe = (frameType == 1);

        if (self.waitingForKeyframe) {
            if (!isKeyframe) return;  // Skip until first keyframe
            self.waitingForKeyframe = NO;
            VCLog(@"[RTMPClient] Got first keyframe at ts=%u!", ts);
        }

        if (self.decoder.isReady) {
            NSData *naluData = [NSData dataWithBytes:data + 5 length:length - 5];
            [self.decoder decodeAVCC:naluData isKeyframe:isKeyframe timestamp:ts];
        }
    }
}

- (void)_parseAVCSequenceHeader:(uint8_t *)data length:(uint32_t)length {
    /*
     * AVCDecoderConfigurationRecord:
     * [0] configurationVersion = 1
     * [1] AVCProfileIndication
     * [2] profile_compatibility
     * [3] AVCLevelIndication
     * [4] lengthSizeMinusOne (& 0x03) → NAL unit length size
     * [5] numOfSPS (& 0x1F)
     * [6..7] spsLength
     * [8..8+spsLength] SPS data
     * [next] numOfPPS
     * [next+1..next+2] ppsLength
     * [next+3..] PPS data
     */

    if (length < 8) return;

    uint8_t configVersion = data[0];
    if (configVersion != 1) {
        VCLog(@"RTMPClient: unexpected AVC config version: %d", configVersion);
        return;
    }

    uint8_t numSPS = data[5] & 0x1F;
    if (numSPS < 1) return;

    uint32_t offset = 6;

    // Read first SPS
    if (offset + 2 > length) return;
    uint16_t spsLen = (data[offset] << 8) | data[offset + 1];
    offset += 2;

    if (offset + spsLen > length) return;
    NSData *sps = [NSData dataWithBytes:data + offset length:spsLen];
    offset += spsLen;

    // Skip remaining SPS
    for (int i = 1; i < numSPS; i++) {
        if (offset + 2 > length) return;
        uint16_t len = (data[offset] << 8) | data[offset + 1];
        offset += 2 + len;
    }

    // Read PPS
    if (offset >= length) return;
    uint8_t numPPS = data[offset];
    offset++;

    if (numPPS < 1 || offset + 2 > length) return;
    uint16_t ppsLen = (data[offset] << 8) | data[offset + 1];
    offset += 2;

    if (offset + ppsLen > length) return;
    NSData *pps = [NSData dataWithBytes:data + offset length:ppsLen];

    VCLog(@"RTMPClient: SPS(%d bytes) PPS(%d bytes)", (int)spsLen, (int)ppsLen);

    // Setup decoder with SPS/PPS
    [self.decoder setupWithSPS:sps pps:pps];
}

#pragma mark - Reconnect

- (void)_scheduleReconnectWithDelay:(NSTimeInterval)delay generation:(NSUInteger)gen {
    if (gen != self.generation || !_isRunning) return;

    [self _cancelReconnect];

    VCLog(@"RTMPClient: reconnecting in %.0fs...", delay);

    self.reconnectTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _rtmpQueue);
    dispatch_source_set_timer(self.reconnectTimer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                              DISPATCH_TIME_FOREVER, 0);

    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(self.reconnectTimer, ^{
        [weakSelf _cancelReconnect];
        if (gen == weakSelf.generation && weakSelf.isRunning) {
            [weakSelf _connectAndPullWithGeneration:gen];
        }
    });

    dispatch_resume(self.reconnectTimer);
}

- (void)_cancelReconnect {
    if (self.reconnectTimer) {
        dispatch_source_cancel(self.reconnectTimer);
        self.reconnectTimer = nil;
    }
}

#pragma mark - Cleanup

- (void)_closeRTMP {
    if (_rtmp) {
        if (RTMP_IsConnected(_rtmp)) {
            RTMP_Close(_rtmp);
        }
        RTMP_Free(_rtmp);
        _rtmp = NULL;
    }
    _isConnected = NO;
}

- (void)_notifyError:(NSString *)error {
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self.delegate respondsToSelector:@selector(rtmpClient:didFailWithError:)]) {
            [self.delegate rtmpClient:self didFailWithError:error];
        }
    });
}

@end
