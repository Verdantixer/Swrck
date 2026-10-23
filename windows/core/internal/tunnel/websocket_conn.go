//go:build windows

package tunnel

import (
	"context"
	"errors"
	"net"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

// websocketStreamConn presents WebSocket messages as a byte stream, matching
// the Android client's WebSocketStreams behavior expected by the SWK2 framing.
type websocketStreamConn struct {
	conn    *websocket.Conn
	ctx     context.Context
	readMu  sync.Mutex
	writeMu sync.Mutex
	buffer  []byte
	offset  int
	closed  sync.Once
}

func newWebSocketStreamConn(ctx context.Context, conn *websocket.Conn) net.Conn {
	stream := &websocketStreamConn{conn: conn, ctx: ctx}
	go func() {
		<-ctx.Done()
		_ = stream.Close()
	}()
	return stream
}

func (c *websocketStreamConn) Read(p []byte) (int, error) {
	if len(p) == 0 {
		return 0, nil
	}
	c.readMu.Lock()
	defer c.readMu.Unlock()
	for c.offset >= len(c.buffer) {
		messageType, message, err := c.conn.ReadMessage()
		if err != nil {
			return 0, err
		}
		if messageType != websocket.BinaryMessage {
			return 0, errors.New("Swock WebSocket tunnel received a non-binary message")
		}
		if len(message) == 0 {
			continue
		}
		c.buffer, c.offset = message, 0
	}
	n := copy(p, c.buffer[c.offset:])
	c.offset += n
	return n, nil
}

func (c *websocketStreamConn) Write(p []byte) (int, error) {
	if len(p) == 0 {
		return 0, nil
	}
	c.writeMu.Lock()
	defer c.writeMu.Unlock()
	if err := c.conn.WriteMessage(websocket.BinaryMessage, p); err != nil {
		return 0, err
	}
	return len(p), nil
}

func (c *websocketStreamConn) Close() error {
	var err error
	c.closed.Do(func() { err = c.conn.Close() })
	return err
}

func (c *websocketStreamConn) LocalAddr() net.Addr  { return c.conn.UnderlyingConn().LocalAddr() }
func (c *websocketStreamConn) RemoteAddr() net.Addr { return c.conn.UnderlyingConn().RemoteAddr() }
func (c *websocketStreamConn) SetDeadline(t time.Time) error {
	return c.conn.UnderlyingConn().SetDeadline(t)
}
func (c *websocketStreamConn) SetReadDeadline(t time.Time) error {
	return c.conn.UnderlyingConn().SetReadDeadline(t)
}
func (c *websocketStreamConn) SetWriteDeadline(t time.Time) error {
	return c.conn.UnderlyingConn().SetWriteDeadline(t)
}

var _ net.Conn = (*websocketStreamConn)(nil)
