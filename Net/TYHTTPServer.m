//
//  TYHTTPServer.m
//  TYMemMCP —— 内嵌 HTTP 服务器实现
//

#import "TYHTTPServer.h"
#import "TYMCPServer.h"
#import "TYMemLog.h"

#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <fcntl.h>
#import <errno.h>
#import <string.h>
#import <pthread.h>

#define TY_MCP_MAX_BODY (4 * 1024 * 1024)   // 4MB 请求体上限

static int gListenFD = -1;

@interface TYHTTPServer ()
@property (nonatomic, assign) BOOL running;
@property (nonatomic, assign) uint16_t actualPort;
@property (nonatomic, assign) uint64_t requestCount;
@property (nonatomic, strong, nullable) NSMutableDictionary<NSString *, NSNumber *> *sessions;
@property (nonatomic, strong) NSLock *sessionLock;
@end

@implementation TYHTTPServer

+ (instancetype)shared {
    static TYHTTPServer *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[TYHTTPServer alloc] init]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _requireSessionHeader = YES;
        _sessions = [NSMutableDictionary dictionary];
        _sessionLock = [[NSLock alloc] init];
    }
    return self;
}

- (NSString *)newSessionId {
    // 模仿标准实现的大写 UUID 形式
    CFUUIDRef u = CFUUIDCreate(NULL);
    CFStringRef s = CFUUIDCreateString(NULL, u);
    CFRelease(u);
    NSString *out = [(__bridge NSString *)s uppercaseString];
    CFRelease(s);
    return out;
}

#pragma mark - 启动 / 停止

- (BOOL)startOnPort:(uint16_t)port {
    if (self.running) return YES;

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return NO;

    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = htons(port);

    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        TYMLog(@"bind 失败 port=%u errno=%d", port, errno);
        close(fd);
        return NO;
    }

    // port=0 时回读实际端口
    socklen_t len = sizeof(addr);
    if (getsockname(fd, (struct sockaddr *)&addr, &len) == 0) {
        self.actualPort = ntohs(addr.sin_port);
    }

    if (listen(fd, 16) < 0) {
        TYMLog(@"listen 失败 errno=%d", errno);
        close(fd);
        return NO;
    }

    gListenFD = fd;
    self.running = YES;

    // accept 循环放独立线程（阻塞式）
    pthread_t th;
    pthread_attr_t at;
    pthread_attr_init(&at);
    pthread_attr_setdetachstate(&at, PTHREAD_CREATE_DETACHED);
    pthread_create(&th, &at, TYAcceptLoop, (__bridge void *)self);
    pthread_attr_destroy(&at);

    TYMLog(@"已监听 0.0.0.0:%u", self.actualPort);
    return YES;
}

- (void)stop {
    if (!self.running) return;
    self.running = NO;
    if (gListenFD >= 0) {
        shutdown(gListenFD, SHUT_RDWR);
        close(gListenFD);
        gListenFD = -1;
    }
    TYMLog(@"已停止");
}

#pragma mark - accept 循环

typedef struct { void *server; int fd; } TYConnCtx;

static void *TYAcceptLoop(void *arg) {
    TYHTTPServer *srv = (__bridge TYHTTPServer *)arg;
    while (srv.running && gListenFD >= 0) {
        struct sockaddr_in peer;
        socklen_t plen = sizeof(peer);
        int cfd = accept(gListenFD, (struct sockaddr *)&peer, &plen);
        if (cfd < 0) {
            if (!srv.running) break;
            if (errno == EINTR || errno == ECONNABORTED) continue;
            usleep(50000);
            continue;
        }
        // 每个连接一个 detached 线程
        TYConnCtx *ctx = malloc(sizeof(TYConnCtx));
        ctx->server = (__bridge_retained void *)srv;
        ctx->fd = cfd;
        pthread_t th;
        pthread_attr_t at;
        pthread_attr_init(&at);
        pthread_attr_setdetachstate(&at, PTHREAD_CREATE_DETACHED);
        pthread_create(&th, &at, TYConnThread, ctx);
        pthread_attr_destroy(&at);
    }
    return NULL;
}

#pragma mark - 连接处理

/// 从 socket 读满 n 字节
static BOOL TYReadN(int fd, void *buf, size_t n) {
    size_t got = 0;
    uint8_t *p = buf;
    while (got < n) {
        ssize_t r = recv(fd, p + got, n - got, 0);
        if (r <= 0) return NO;
        got += (size_t)r;
    }
    return YES;
}

/// 读取到 CRLFCRLF（HTTP 头结束）
static BOOL TYReadHeaders(int fd, NSMutableData *out, NSUInteger *bodyStart) {
    uint8_t tmp[1024];
    while (YES) {
        ssize_t r = recv(fd, tmp, sizeof(tmp), 0);
        if (r <= 0) return NO;
        [out appendBytes:tmp length:(NSUInteger)r];
        // 查 \r\n\r\n
        const uint8_t *b = out.bytes;
        NSUInteger n = out.length;
        for (NSUInteger i = 0; i + 3 < n; i++) {
            if (b[i] == '\r' && b[i+1] == '\n' && b[i+2] == '\r' && b[i+3] == '\n') {
                *bodyStart = i + 4;
                return YES;
            }
        }
        if (out.length > 64 * 1024) return NO;   // 头过大
    }
}

static void TYSendAll(int fd, const void *buf, size_t n) {
    const uint8_t *p = buf;
    size_t sent = 0;
    while (sent < n) {
        ssize_t r = send(fd, p + sent, n - sent, 0);
        if (r <= 0) return;
        sent += (size_t)r;
    }
}

static void TYSendJSON(int fd, int code, NSString *status, NSDictionary *obj,
                       NSString *extraSession) {
    NSData *body = [NSJSONSerialization dataWithJSONObject:obj options:0 error:NULL];
    if (!body) body = [@"{}" dataUsingEncoding:NSUTF8StringEncoding];

    NSMutableString *h = [NSMutableString string];
    [h appendFormat:@"HTTP/1.1 %d %@\r\n", code, status];
    [h appendString:@"Content-Type: application/json\r\n"];
    [h appendFormat:@"Content-Length: %lu\r\n", (unsigned long)body.length];
    [h appendString:@"Connection: close\r\n"];
    if (extraSession.length) [h appendFormat:@"MCP-Session-Id: %@\r\n", extraSession];
    [h appendString:@"Access-Control-Allow-Origin: *\r\n"];
    [h appendString:@"Access-Control-Allow-Headers: Content-Type, Accept, MCP-Session-Id\r\n"];
    [h appendString:@"Access-Control-Allow-Methods: POST, GET, OPTIONS, DELETE\r\n"];
    [h appendString:@"\r\n"];

    NSMutableData *resp = [NSMutableData data];
    [resp appendData:[h dataUsingEncoding:NSUTF8StringEncoding]];
    [resp appendData:body];
    TYSendAll(fd, resp.bytes, resp.length);
}

static void TYSendText(int fd, int code, NSString *status, NSString *text) {
    NSData *body = [text dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    NSMutableString *h = [NSMutableString string];
    [h appendFormat:@"HTTP/1.1 %d %@\r\n", code, status];
    [h appendString:@"Content-Type: text/plain; charset=utf-8\r\n"];
    [h appendFormat:@"Content-Length: %lu\r\n", (unsigned long)body.length];
    [h appendString:@"Connection: close\r\n\r\n"];
    NSMutableData *resp = [NSMutableData data];
    [resp appendData:[h dataUsingEncoding:NSUTF8StringEncoding]];
    [resp appendData:body];
    TYSendAll(fd, resp.bytes, resp.length);
}

static void *TYConnThread(void *arg) {
    TYConnCtx *ctx = (TYConnCtx *)arg;
    TYHTTPServer *srv = (__bridge TYHTTPServer *)ctx->server;
    int fd = ctx->fd;

    @autoreleasepool {
        NSMutableData *hdr = [NSMutableData data];
        NSUInteger bodyStart = 0;
        if (!TYReadHeaders(fd, hdr, &bodyStart)) { close(fd); goto done; }

        NSString *hdrStr = [[NSString alloc] initWithData:hdr encoding:NSUTF8StringEncoding];
        NSArray *lines = [hdrStr componentsSeparatedByString:@"\r\n"];
        if (!lines.count) { close(fd); goto done; }

        // 请求行
        NSArray *parts = [lines[0] componentsSeparatedByString:@" "];
        if (parts.count < 2) { close(fd); goto done; }
        NSString *method = parts[0];
        NSString *path = parts[1];

        // 头
        NSMutableDictionary *headers = [NSMutableDictionary dictionary];
        for (NSUInteger i = 1; i < lines.count; i++) {
            NSString *l = lines[i];
            NSRange c = [l rangeOfString:@":"];
            if (c.location == NSNotFound) continue;
            NSString *k = [[l substringToIndex:c.location] lowercaseString];
            NSString *v = [[l substringFromIndex:c.location + 1]
                           stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if (k.length) headers[k] = v;
        }

        // 方法分发（CORS 预检）
        if ([method isEqualToString:@"OPTIONS"]) {
            TYSendText(fd, 204, @"No Content", @"");
            close(fd); goto done;
        }

        if ([path hasPrefix:@"/health"]) {
            NSDictionary *st = @{@"ok": @YES,
                                 @"server": @"ty-mem-mcp",
                                 @"port": @(srv.actualPort),
                                 @"requests": @(srv.requestCount)};
            TYSendJSON(fd, 200, @"OK", st, nil);
            close(fd); goto done;
        }

        if ([method isEqualToString:@"GET"]) {
            // MCP 标准里 GET 用于 SSE 流；我们不提供，按要求回报
            TYSendJSON(fd, 405, @"Method Not Allowed",
                       @{@"error": @"本服务器不支持 SSE 流式；请用 POST /mcp 发送 JSON-RPC"},
                       nil);
            close(fd); goto done;
        }

        if (![method isEqualToString:@"POST"]) {
            TYSendJSON(fd, 405, @"Method Not Allowed", @{@"error": @"仅支持 POST"}, nil);
            close(fd); goto done;
        }

        // 读 body
        NSInteger contentLen = [headers[@"content-length"] integerValue];
        if (contentLen < 0) contentLen = 0;
        if (contentLen > TY_MCP_MAX_BODY) {
            TYSendJSON(fd, 413, @"Payload Too Large",
                       @{@"error": [NSString stringWithFormat:@"请求体过大（上限 %d 字节）", TY_MCP_MAX_BODY]},
                       nil);
            close(fd); goto done;
        }

        NSMutableData *body = [NSMutableData data];
        if (hdr.length > bodyStart) {
            [body appendData:[hdr subdataWithRange:NSMakeRange(bodyStart, hdr.length - bodyStart)]];
        }
        if ((NSInteger)body.length < contentLen) {
            NSUInteger need = (NSUInteger)contentLen - body.length;
            NSMutableData *rest = [NSMutableData dataWithLength:need];
            if (need && !TYReadN(fd, rest.mutableBytes, need)) {
                TYSendJSON(fd, 400, @"Bad Request", @{@"error": @"读取请求体失败"}, nil);
                close(fd); goto done;
            }
            [body appendData:rest];
        }

        NSString *sid = headers[@"mcp-session-id"];

        // session 校验：模仿标准实现 —— 第一次 initialize 时不校验，
        // 之后的请求必须带同一个 session id。
        id parsed = nil;
        if (body.length) {
            parsed = [NSJSONSerialization JSONObjectWithData:body options:0 error:NULL];
        }
        if (!parsed) {
            TYSendJSON(fd, 400, @"Bad Request", @{@"error": @"请求体不是合法 JSON"}, nil);
            close(fd); goto done;
        }

        NSString *reqMethod = [parsed isKindOfClass:[NSDictionary class]] ? parsed[@"method"] : nil;
        BOOL isInit = [reqMethod isEqualToString:@"initialize"];

        if (srv.requireSessionHeader && !isInit) {
            if (!sid.length) {
                TYSendJSON(fd, 400, @"Bad Request",
                           @{@"error": @"MCP-Session-Id required"}, nil);
                close(fd); goto done;
            }
            [srv.sessionLock lock];
            BOOL known = srv.sessions[sid] != nil;
            [srv.sessionLock unlock];
            if (!known) {
                TYSendJSON(fd, 400, @"Bad Request",
                           @{@"error": @"Session not initialized", @"code": @(-32002)}, nil);
                close(fd); goto done;
            }
        }

        // 分发
        NSDictionary *resp = nil;
        if ([parsed isKindOfClass:[NSArray class]]) {
            // 批量请求：逐条处理
            NSMutableArray *out = [NSMutableArray array];
            for (NSDictionary *one in (NSArray *)parsed) {
                NSDictionary *r = [[TYMCPServer shared] handle:one];
                if (r) [out addObject:r];
            }
            resp = @{@"__batch": out};
        } else if ([parsed isKindOfClass:[NSDictionary class]]) {
            resp = [[TYMCPServer shared] handle:(NSDictionary *)parsed];
        }

        // initialize：登记 session 并回带 session id
        NSString *newSid = nil;
        if (isInit) {
            newSid = sid.length ? sid : [srv newSessionId];
            [srv.sessionLock lock];
            srv.sessions[newSid] = @([[NSDate date] timeIntervalSince1970]);
            [srv.sessionLock unlock];
        }

        srv.requestCount++;

        if (!resp) {
            // 通知类：204
            TYSendText(fd, 204, @"No Content", @"");
            close(fd); goto done;
        }
        if (resp[@"__batch"]) {
            TYSendJSON(fd, 200, @"OK", @{@"result": resp[@"__batch"]}, newSid);
            close(fd); goto done;
        }
        TYSendJSON(fd, 200, @"OK", resp, newSid);
        close(fd);
    }

done:
    CFRelease(ctx->server);
    free(ctx);
    return NULL;
}

@end
