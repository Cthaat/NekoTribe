// server/routes/_ws.ts
export default defineWebSocketHandler({
  // 当一个新的客户端连接时调用
  open(peer) {
    console.log("[ws] open", peer);
    peer.send("欢迎连接到 WebSocket 服务器！");
  },

  // 当从客户端收到消息时调用
  message(peer, message) {
    console.log("[ws] message", peer, message);
    if (message.text().includes("ping")) {
      peer.send("pong");
    } else {
      // 将收到的消息广播给所有连接的客户端
      peer.send(`你发送了: ${message.text()}`);
    }
  },

  // 当客户端连接关闭时调用
  close(peer, event) {
    console.log("[ws] close", peer, event);
  },

  // 当发生错误时调用
  error(peer, error) {
    console.log("[ws] error", peer, error);
  },
});