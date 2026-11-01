//
//  TYHTTPServer.h
//  TYMemMCP —— 内嵌 HTTP 服务器（MCP Streamable HTTP 子集）
//
//  ═══════════════════════════════════════════════════════════════════════
//  为什么用 BSD socket 手写而不是 NSURLSession / GCDWebServer
//  ═══════════════════════════════════════════════════════════════════════
//
//  · GCDWebServer 是第三方依赖，要塞进 dylib 会显著增大体积，
//    且它的初始化会装 runloop source，在游戏进程里有干扰风险。
//  · NSURLSession 是客户端，不能起服务。
//  · 我们只需要处理极少量的短请求（MCP 工具调用），
//    用阻塞式 accept + 每连接一个 detached 线程完全够用，
//    实现透明、无依赖、出问题好定位。
//
//  协议实现（Streamable HTTP 的最小可用子集）：
//    POST /mcp   带 JSON-RPC 请求体
//    响应 application/json（不启用 SSE 流式，客户端一般都能接受）
//    GET  /mcp   返回 400 + 提示（要求带 session header）
//    GET  /health 返回 200 OK
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface TYHTTPServer : NSObject
+ (instancetype)shared;

/// 启动监听。port=0 时自动选一个（实际端口用 -actualPort 取）。
/// 返回是否成功启动。
- (BOOL)startOnPort:(uint16_t)port;

- (void)stop;

@property (nonatomic, readonly) BOOL running;
@property (nonatomic, readonly) uint16_t actualPort;
@property (nonatomic, readonly) uint64_t requestCount;

/// 是否强制校验 MCP-Session-Id（默认 YES，模仿标准实现）
@property (nonatomic, assign) BOOL requireSessionHeader;

/// 生成并返回一个新的 session id（测试用）
- (NSString *)newSessionId;
@end

NS_ASSUME_NONNULL_END
