//
//  TYMCPServer.h
//  TYMemMCP —— MCP (Model Context Protocol) JSON-RPC 分发
//
//  实现 MCP 2024-11-05 的核心子集：
//    initialize            能力协商，回 protocolVersion / serverInfo / capabilities
//    notifications/initialized   客户端确认通知（无响应）
//    tools/list            工具清单（含 inputSchema）
//    tools/call            调用工具
//    ping                  保活
//
//  与 MT-MCP 的差异：本服务器**在同一进程内**（游戏进程），
//  因此读内存不需要 task_for_pid 提权，也不需要额外签名。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface TYMCPServer : NSObject
+ (instancetype)shared;

/// 处理一条 JSON-RPC 请求，返回响应字典（通知类返回 nil）
- (nullable NSDictionary *)handle:(NSDictionary *)request;

/// 工具清单（tools/list 的 result）
- (NSDictionary *)toolList;

/// 服务器信息
- (NSDictionary *)serverInfo;
@end

NS_ASSUME_NONNULL_END
