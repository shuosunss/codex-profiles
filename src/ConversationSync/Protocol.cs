using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Net.WebSockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;

// 只承载本机调试协议，不访问账户接口或远程网络。
internal interface ILocalChannel : IDisposable
{
    event Action<string> Received;
    void Send(string message);
}

internal sealed class LoopbackChannel : ILocalChannel
{
    private readonly ClientWebSocket socket = new ClientWebSocket();
    private readonly CancellationTokenSource cancel = new CancellationTokenSource();
    public event Action<string> Received;

    public LoopbackChannel(Uri endpoint)
    {
        // Each profile reuses its own loopback-only random enhancement port.
        if (endpoint.Scheme != "ws" || endpoint.Host != "127.0.0.1")
            throw new InvalidOperationException("Only a local debugging endpoint is allowed");
        socket.Options.Proxy = null;
        using (var timeout = new CancellationTokenSource(10000))
            socket.ConnectAsync(endpoint, timeout.Token).GetAwaiter().GetResult();
        new Thread(Read) { IsBackground = true }.Start();
    }

    private void Read()
    {
        try
        {
            byte[] buffer = new byte[16384];
            while (!cancel.IsCancellationRequested)
            {
                using (var message = new MemoryStream())
                {
                    WebSocketReceiveResult result;
                    do
                    {
                        result = socket.ReceiveAsync(new ArraySegment<byte>(buffer), cancel.Token).GetAwaiter().GetResult();
                        if (result.MessageType == WebSocketMessageType.Close) return;
                        message.Write(buffer, 0, result.Count);
                    }
                    while (!result.EndOfMessage);
                    Action<string> callback = Received;
                    if (callback != null) callback(Encoding.UTF8.GetString(message.ToArray()));
                }
            }
        }
        catch (OperationCanceledException) { }
        catch (WebSocketException) { }
        catch (ObjectDisposedException) { }
    }

    public void Send(string message)
    {
        byte[] bytes = Encoding.UTF8.GetBytes(message);
        socket.SendAsync(new ArraySegment<byte>(bytes), WebSocketMessageType.Text, true, cancel.Token)
            .GetAwaiter().GetResult();
    }

    public void Dispose()
    {
        cancel.Cancel();
        socket.Dispose();
        cancel.Dispose();
    }
}

internal sealed class LocalProtocol : IDisposable
{
    private readonly ILocalChannel channel;
    private readonly ConcurrentDictionary<int, TaskCompletionSource<Dictionary<string, object>>> waiting =
        new ConcurrentDictionary<int, TaskCompletionSource<Dictionary<string, object>>>();
    private int sequence;

    public LocalProtocol(ILocalChannel channel)
    {
        this.channel = channel;
        channel.Received += Receive;
    }

    private void Receive(string message)
    {
        var value = Json.Parse(message);
        if (!value.ContainsKey("id")) return;
        TaskCompletionSource<Dictionary<string, object>> request;
        if (waiting.TryRemove(Convert.ToInt32(value["id"]), out request))
        {
            if (value.ContainsKey("error")) request.TrySetException(new IOException(Json.Stringify(value["error"])));
            else request.TrySetResult(Json.Object(value, "result"));
        }
    }

    public Dictionary<string, object> Call(string method, object parameters = null, string session = null)
    {
        int id = Interlocked.Increment(ref sequence);
        var request = new TaskCompletionSource<Dictionary<string, object>>();
        waiting[id] = request;
        var payload = new Dictionary<string, object> { { "id", id }, { "method", method } };
        if (parameters != null) payload["params"] = parameters;
        if (session != null) payload["sessionId"] = session;
        try
        {
            channel.Send(Json.Stringify(payload));
            if (!request.Task.Wait(15000)) throw new IOException("Local protocol timed out: " + method);
            return request.Task.GetAwaiter().GetResult();
        }
        finally
        {
            TaskCompletionSource<Dictionary<string, object>> removed;
            waiting.TryRemove(id, out removed);
        }
    }

    public void Dispose()
    {
        channel.Dispose();
    }
}

internal static class Json
{
    public static string Stringify(object value)
    {
        return new JavaScriptSerializer { MaxJsonLength = 4 * 1024 * 1024 }.Serialize(value);
    }

    public static Dictionary<string, object> Parse(string value)
    {
        return new JavaScriptSerializer { MaxJsonLength = 4 * 1024 * 1024 }
            .Deserialize<Dictionary<string, object>>(value);
    }

    public static Dictionary<string, object> Object(Dictionary<string, object> value, string key)
    {
        object item;
        return value.TryGetValue(key, out item) && item is Dictionary<string, object>
            ? (Dictionary<string, object>)item : new Dictionary<string, object>();
    }

    public static string Text(Dictionary<string, object> value, string key)
    {
        object item;
        return value.TryGetValue(key, out item) && item != null ? Convert.ToString(item) : "";
    }
}
