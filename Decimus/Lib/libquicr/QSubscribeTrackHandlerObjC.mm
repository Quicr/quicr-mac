////
////  QSubscribeTrackHandler.mm
////  Decimus
////
////  Created by Scott Henning on 8/27/24.
////
//
//#import <Foundation/Foundation.h>
//
//@implementation QSubscribeTrackHandlerObjC : NSObject
//
//-(id) initWithFullTrackName: fullTrackName: (SubFullTrackName) full_track_name
//{
//    moq::FullTrackName fullTrackName;
//    // I know this doesn't work... just placehodler.
//    fullTrackName.name_space =(uint8_t *)full_track_name.nameSpace.UTF8String;
//    fullTrackName.name = (uint8_t *)full_track_name.name.UTF8String;
//
//    // allocate handler...
//    _handlerPtr = std::make_shared<QSubscribeTrackHandler>(fullTrackName);
//}
//
//
//-(void) setCallbacks: (id<QSubscribeTrackHandlerCallbacks>) callbacks
//{
//    if (handlerPtr)
//    {
//        handlerPtr->SetCallbacks(callbacks);
//    }
//}
//
//// C++
//
//QSubscribeTrackHandler::QSubscribeTrackHandler(const FullTrackName& full_track_name): moq::SubscribeTrackHandler(full_track_name)
//{
//}
//
//void QSubscribeTrackHandler::StatusChanged(Status status)
//{
//    if (callbacks)
//    {
//        [callbacks statusChanged: (int) status];
//    }
//}
//
//void QSubscriberTrackHandler::ObjectReceived(const ObjectHeaders& object_headers,
//                                            Span<uint8_t> data)
//{
//    if (callbacks)
//    {
//        [callbacks objectReceivedData: data.data length: data.size]
//    }
//}
//
//void QSubscribeTrackHandler::SetCallbacks(callbacks)
//{
//    _callbacks = callbacks;
//}
