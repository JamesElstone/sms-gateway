import java.net.URI
import java.net.http.HttpClient
import java.net.http.HttpRequest
import java.net.http.HttpResponse
import java.nio.charset.StandardCharsets

fun main(args: Array<String>) {
    if (args.size < 4) {
        System.err.println("Usage: kotlin send_sms.kt BASE_URL TOKEN MOBILE MESSAGE [MESSAGE...]")
        System.err.println("Example: kotlin send_sms.kt http://sms.example.net/sms-gateway \$TOKEN +447700900000 Hello from Kotlin")
        kotlin.system.exitProcess(2)
    }

    val baseUrl = args[0].trimEnd('/')
    val token = args[1]
    val mobile = args[2]
    val message = args.drop(3).joinToString(" ")
    val sendUrl = "$baseUrl/send/${encodePathSegment(mobile)}"

    val request = HttpRequest.newBuilder(URI.create(sendUrl))
        .header("X-SMS-Gateway-Token", token)
        .header("Content-Type", "text/plain; charset=utf-8")
        .POST(HttpRequest.BodyPublishers.ofString(message, StandardCharsets.UTF_8))
        .build()

    val response = HttpClient.newHttpClient()
        .send(request, HttpResponse.BodyHandlers.ofString(StandardCharsets.UTF_8))

    println(response.body())

    if (response.statusCode() !in 200..299) {
        System.err.println("Gateway returned HTTP ${response.statusCode()}")
        kotlin.system.exitProcess(1)
    }
}

fun encodePathSegment(value: String): String {
    val hex = "0123456789ABCDEF"
    val output = StringBuilder()

    for (byte in value.toByteArray(StandardCharsets.UTF_8)) {
        val b = byte.toInt() and 0xff
        val char = b.toChar()

        if (
            char in 'A'..'Z' ||
            char in 'a'..'z' ||
            char in '0'..'9' ||
            char == '-' ||
            char == '.' ||
            char == '_' ||
            char == '~'
        ) {
            output.append(char)
        } else {
            output.append('%')
            output.append(hex[b ushr 4])
            output.append(hex[b and 0x0f])
        }
    }

    return output.toString()
}
