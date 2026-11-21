package tvbox.runtime;

import java.nio.charset.StandardCharsets;
import java.util.Base64;
import java.util.concurrent.ConcurrentHashMap;
import org.json.JSONObject;

/**
 * The sign-in for a subscription host (e.g. a Xiaoya/Alist server with forced login on),
 * as the app saved it for that host. The Swift side passes only the already-encoded
 * {@code Authorization: Basic ...} header value for the subscription's host; this holder
 * keeps it per host (one JVM serves many subscriptions) and decodes it only so the AList
 * spider's {@code drives[].login} can be filled in. Nothing here ever logs a credential:
 * callers must not print the header, the decoded password, or a request URL carrying one.
 */
public final class SubscriptionAuth {
    private static final ConcurrentHashMap<String, String> HEADERS = new ConcurrentHashMap<>();
    private static final ConcurrentHashMap<String, String> USERNAMES = new ConcurrentHashMap<>();
    private static final ConcurrentHashMap<String, String> PASSWORDS = new ConcurrentHashMap<>();

    private SubscriptionAuth() { }

    /** Registers the sign-in from the Swift input {@code {"host": ..., "authorization": "Basic ..."}}. */
    public static void set(JSONObject auth) {
        if (auth == null) return;
        String host = auth.optString("host", "").trim().toLowerCase();
        String header = auth.optString("authorization", "").trim();
        if (host.isEmpty() || !header.startsWith("Basic ")) return;
        HEADERS.put(host, header);
        try {
            String decoded = new String(Base64.getDecoder().decode(header.substring("Basic ".length()).trim()), StandardCharsets.UTF_8);
            int split = decoded.indexOf(':');
            if (split > 0) {
                USERNAMES.put(host, decoded.substring(0, split));
                PASSWORDS.put(host, decoded.substring(split + 1));
            }
        } catch (IllegalArgumentException unreadable) {
            // A malformed header still authenticates raw HTTP requests; only the
            // AList login fill-in below is skipped.
        }
    }

    /** The {@code Authorization} header for this host, or null when no sign-in was saved. */
    public static String headerFor(String host) {
        if (host == null) return null;
        return HEADERS.get(host.toLowerCase());
    }

    public static String usernameFor(String host) {
        if (host == null) return null;
        return USERNAMES.get(host.toLowerCase());
    }

    public static String passwordFor(String host) {
        if (host == null) return null;
        return PASSWORDS.get(host.toLowerCase());
    }

    /** The host (lower-cased) of a server URL, or null when it has none. */
    public static String hostOf(String server) {
        if (server == null || server.isBlank()) return null;
        try { return new java.net.URL(server).getHost().toLowerCase(); }
        catch (Exception notAUrl) { return null; }
    }
}
