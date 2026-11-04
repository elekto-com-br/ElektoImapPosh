# Puts TLS in front of an IMAP server that has none, such as smtp4dev, for the tests of encrypted connections:
# from the start (implicit TLS, as on port 993), or after STARTTLS, which the proxy adds to the capabilities the
# server announces, and answers itself. The certificate is self-signed, for localhost and 127.0.0.1, made in
# memory and never put in a certificate store, so a client that checks certificates refuses it.
# In C#, since the proxy serves connections on threads of its own, where a script block has no runspace.

if (-not ('ElektoImapPoshTests.TlsProxy' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace ElektoImapPoshTests
{
    public sealed class TlsProxy : IDisposable
    {
        private readonly TcpListener listener;
        private readonly int upstreamPort;
        private readonly bool startTls;
        private readonly X509Certificate2 certificate;
        private readonly CancellationTokenSource stop = new CancellationTokenSource();
        private int handshakes;

        public int Port { get; private set; }

        // TLS handshakes completed with clients
        public int Handshakes { get { return Volatile.Read(ref handshakes); } }

        // Listens on the loopback, on the port given (0 for any free one), and relays to the upstream port
        public TlsProxy(int upstreamPort, bool startTls, int port)
        {
            this.upstreamPort = upstreamPort;
            this.startTls = startTls;
            certificate = CreateCertificate();
            listener = new TcpListener(IPAddress.Loopback, port);
            try { listener.Start(); }
            catch { certificate.Dispose(); throw; }
            Port = ((IPEndPoint)listener.LocalEndpoint).Port;
            Task.Run(AcceptAsync);
        }

        private static X509Certificate2 CreateCertificate()
        {
            using (RSA key = RSA.Create(2048))
            {
                var request = new CertificateRequest("CN=localhost", key, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
                var names = new SubjectAlternativeNameBuilder();
                names.AddDnsName("localhost");
                names.AddIpAddress(IPAddress.Loopback);
                request.CertificateExtensions.Add(names.Build());
                request.CertificateExtensions.Add(new X509EnhancedKeyUsageExtension(new OidCollection { new Oid("1.3.6.1.5.5.7.3.1") }, false));
                using (X509Certificate2 created = request.CreateSelfSigned(DateTimeOffset.UtcNow.AddMinutes(-5), DateTimeOffset.UtcNow.AddDays(1)))
                {
                    // On Windows, a server certificate needs its key in the user's key store: one only in
                    // memory (EphemeralKeySet) fails the handshake (tested). This one is deleted with the
                    // certificate, in Dispose, so nothing stays behind
                    return X509CertificateLoader.LoadPkcs12(created.Export(X509ContentType.Pkcs12), null);
                }
            }
        }

        private async Task AcceptAsync()
        {
            while (!stop.IsCancellationRequested)
            {
                TcpClient client;
                try { client = await listener.AcceptTcpClientAsync(stop.Token); }
                catch { return; }
                _ = Task.Run(() => ServeAsync(client));
            }
        }

        private async Task ServeAsync(TcpClient client)
        {
            using (client)
            using (var upstream = new TcpClient())
            {
                try
                {
                    await upstream.ConnectAsync(IPAddress.Loopback, upstreamPort, stop.Token);
                    Stream plain = client.GetStream();
                    Stream server = upstream.GetStream();
                    if (startTls && !await RelayUntilStartTlsAsync(plain, server)) return;
                    using (var tls = new SslStream(plain, false))
                    {
                        await tls.AuthenticateAsServerAsync(new SslServerAuthenticationOptions { ServerCertificate = certificate }, stop.Token);
                        Interlocked.Increment(ref handshakes);
                        await Task.WhenAny(tls.CopyToAsync(server, stop.Token), server.CopyToAsync(tls, stop.Token));
                    }
                }
                catch
                {
                    // A client that refuses the certificate, or either end closing
                }
            }
        }

        // Relays line by line, adding STARTTLS to the capabilities, until the client sends STARTTLS, which is
        // answered here: the server never sees it, and the client goes on in TLS with the proxy
        private static async Task<bool> RelayUntilStartTlsAsync(Stream client, Stream server)
        {
            string greeting = await ReadLineAsync(server);
            if (greeting == null) return false;
            await WriteAsync(client, AddStartTls(greeting));
            while (true)
            {
                string command = await ReadLineAsync(client);
                if (command == null) return false;
                string[] words = command.TrimEnd('\r', '\n').Split(' ');
                if (words.Length == 2 && words[1].Equals("STARTTLS", StringComparison.OrdinalIgnoreCase))
                {
                    await WriteAsync(client, words[0] + " OK Begin TLS negotiation now\r\n");
                    return true;
                }
                await WriteAsync(server, command);
                while (true)
                {
                    string answer = await ReadLineAsync(server);
                    if (answer == null) return false;
                    await WriteAsync(client, AddStartTls(answer));
                    if (answer.StartsWith(words[0] + " ", StringComparison.Ordinal)) break;
                }
            }
        }

        private static string AddStartTls(string line)
        {
            if (line.StartsWith("* CAPABILITY ", StringComparison.OrdinalIgnoreCase)) return line.TrimEnd('\r', '\n') + " STARTTLS\r\n";
            int start = line.IndexOf("[CAPABILITY ", StringComparison.OrdinalIgnoreCase);
            if (start < 0) return line;
            int end = line.IndexOf(']', start);
            return line.Substring(0, end) + " STARTTLS" + line.Substring(end);
        }

        // A byte at a time, so that nothing after the line is read ahead of the TLS handshake
        private static async Task<string> ReadLineAsync(Stream stream)
        {
            var line = new MemoryStream();
            var one = new byte[1];
            while (true)
            {
                if (await stream.ReadAsync(one, 0, 1) == 0) return null;
                line.WriteByte(one[0]);
                if (one[0] == (byte)'\n') return Encoding.ASCII.GetString(line.ToArray());
            }
        }

        private static Task WriteAsync(Stream stream, string text)
        {
            byte[] bytes = Encoding.ASCII.GetBytes(text);
            return stream.WriteAsync(bytes, 0, bytes.Length);
        }

        public void Dispose()
        {
            stop.Cancel();
            listener.Stop();
            certificate.Dispose();
        }
    }
}
'@
}
