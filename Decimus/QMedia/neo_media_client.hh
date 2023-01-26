#ifndef NEO_MEDIA_CLIENT_HH
#define NEO_MEDIA_CLIENT_HH

#include <stdint.h>

typedef void( *SubscribeCallback)(uint64_t id, uint8_t *data, uint32_t length);

#ifdef __cplusplus
extern "C"
{
#endif
    void
    MediaClient_Create(const char *remote_address,
                       uint16_t remote_port,
                       void **media_client);

    void
    MediaClient_Destroy(void *media_client);

    uint64_t 
    MediaClient_AddAudioStreamPublishIntent(void *instance,
                                            uint8_t codec_type);

    uint64_t 
    MediaClient_AddAudioStreamSubscribe(void *instance,
                                        uint8_t  codec_type,
                                        SubscribeCallback callback);

    uint64_t 
    MediaClient_AddVideoStreamPublishIntent(void *instance,
                                            uint8_t codec_type);


    uint64_t 
    MediaClient_AddVideoStreamSubscribe(void *instance,
                                        uint8_t codec_type,
                                        SubscribeCallback callback);


    void 
    MediaClient_RemoveMediaStream(void *instance,
                                  uint64_t media_stream_id);

    void  MediaClient_sendAudio(void *instance,
                                uint64_t media_stream_id,
                                const char *buffer,
                                uint16_t length,
                                uint64_t timestamp);

    void
    MediaClient_sendVideoFrame(void *instance,
                               uint64_t streamId,
                               const char *buffer,
                               uint16_t length,
                               uint64_t timestamp,
                               uint8_t flag);

#ifdef __cplusplus
}
#endif
#endif
