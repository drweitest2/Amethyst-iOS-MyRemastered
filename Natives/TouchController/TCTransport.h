//
// TCTransport.h
// Simple Unix domain socket "launcher" transport for TouchController
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// 启动 server。socketName 与 TouchController mod 中的 TOUCH_CONTROLLER_PROXY_SOCKET 必须一致。
// 如果 socketName 为空，将使用 "AmethystLauncher" 作为默认名。
// 该函数在后台线程接受客户端连接并保持运行。
void TC_StartServer(NSString * _Nullable socketName);

// 停止 server 并关闭连接
void TC_StopServer(void);

// 发送 AddPointer(index, x, y)
void TC_SendAddPointer(int32_t index, float x, float y);

// 发送 RemovePointer(index)
void TC_SendRemovePointer(int32_t index);

// 发送 ClearPointer()
void TC_SendClearPointer(void);

// 发送 MoveView (可选)：screenBased -> 1 byte, then 2 floats
void TC_SendMoveView(BOOL screenBased, float deltaPitch, float deltaYaw);

NS_ASSUME_NONNULL_END