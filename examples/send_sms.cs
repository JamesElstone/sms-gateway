using System;
using System.Net.Http;
using System.Text;
using System.Threading.Tasks;

internal static class SendSmsExample
{
    private static async Task<int> Main(string[] args)
    {
        if (args.Length < 4)
        {
            Console.Error.WriteLine("Usage: send-sms BASE_URL TOKEN MOBILE MESSAGE [MESSAGE...]");
            Console.Error.WriteLine("Example: send-sms http://sms.example.net/sms-gateway $TOKEN +447700900000 Hello from C#");
            return 2;
        }

        var baseUrl = args[0].TrimEnd('/');
        var token = args[1];
        var mobile = args[2];
        var message = string.Join(" ", args, 3, args.Length - 3);
        var sendUrl = $"{baseUrl}/send/{Uri.EscapeDataString(mobile)}";

        using var http = new HttpClient();
        using var request = new HttpRequestMessage(HttpMethod.Post, sendUrl)
        {
            Content = new StringContent(message, Encoding.UTF8, "text/plain")
        };
        request.Headers.Add("X-SMS-Gateway-Token", token);

        using var response = await http.SendAsync(request);
        var responseBody = await response.Content.ReadAsStringAsync();

        Console.WriteLine(responseBody);

        if (!response.IsSuccessStatusCode)
        {
            Console.Error.WriteLine($"Gateway returned HTTP {(int) response.StatusCode}");
            return 1;
        }

        return 0;
    }
}
