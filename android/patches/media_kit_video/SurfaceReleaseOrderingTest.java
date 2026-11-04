import java.nio.file.Files;
import java.nio.file.Path;
import javax.tools.ToolProvider;

/**
 * Runs the patched media_kit_video release methods against a native-object
 * lifecycle fake.
 *
 * The upstream plugin retires android.view.Surface, its Flutter texture entry
 * and the JNI global reference inside Player.dispose, while libmpv destroys its
 * own video output later on a timer the Dart side cannot await. The patch parks
 * those objects until the owner confirms the output is gone. These fakes model
 * only that ordering: they do not exercise libmpv, JNI or a real Android
 * Handler, so the fallback delay is observed as a posted task rather than timed.
 */
class SurfaceReleaseOrderingTest {
    public static void main(String[] args) throws Exception {
        String output = Files.readString(Path.of(args[0]));
        String manager = Files.readString(Path.of(args[1]));
        String plugin = Files.readString(Path.of(args[2]));
        // A Dart caller cannot reach the manager without a channel case, and a
        // case that routes to dispose() would re-park instead of retiring.
        String releaseCase = caseBody(plugin, "VideoOutputManager.ReleaseSurface");
        if (!releaseCase.contains("videoOutputManager.releaseNative(")) {
            throw new AssertionError("ReleaseSurface does not route to releaseNative");
        }
        String methods = method(output, "public void dispose()")
            + method(output, "void releaseNative()")
            + method(output, "private void retireNativeObjects()");
        String managerMethods = method(manager, "public VideoOutput create(long handle)")
            + method(manager, "public void dispose(long handle)")
            + method(manager, "public void releaseNative(long handle)");
        Path dir = Path.of(args[3]);
        Files.createDirectories(dir);
        Path test = dir.resolve("ParkedVideoOutput.java");
        Files.writeString(test, HARNESS
            .replace("// OUTPUT_METHODS", methods)
            .replace("// MANAGER_METHODS", managerMethods)
            .replace("// FALLBACK_FIELD", field(output, "RELEASE_FALLBACK_MILLIS")));
        var compiler = ToolProvider.getSystemJavaCompiler();
        if (compiler == null || compiler.run(null, null, null,
                "--release", "17", "-d", dir.toString(), test.toString()) != 0) {
            throw new AssertionError("Could not compile media_kit_video release regression");
        }
        try (var loader = new java.net.URLClassLoader(new java.net.URL[] {dir.toUri().toURL()})) {
            loader.loadClass("ParkedVideoOutput").getMethod("main", String[].class)
                .invoke(null, (Object) new String[0]);
        }
    }

    private static String method(String source, String signature) {
        int start = source.indexOf(signature);
        if (start < 0) throw new AssertionError("Missing upstream method: " + signature);
        int body = source.indexOf('{', start);
        int depth = 1;
        int end = body + 1;
        while (depth > 0 && end < source.length()) {
            char character = source.charAt(end++);
            if (character == '{') depth++;
            if (character == '}') depth--;
        }
        if (depth != 0) throw new AssertionError("Unterminated method: " + signature);
        return source.substring(start, end) + "\n";
    }

    /** Reuses the patched constant instead of restating it, so a shortened
     *  fallback cannot silently slip inside the core's destroy window. */
    private static String field(String source, String name) {
        for (String line : source.split("\n")) {
            if (line.contains(name) && line.contains("=")) return line.trim();
        }
        throw new AssertionError("Missing patched constant: " + name);
    }

    private static String caseBody(String plugin, String name) {
        int start = plugin.indexOf("case \"" + name + "\":");
        if (start < 0) throw new AssertionError("Missing channel method: " + name);
        int end = plugin.indexOf("break;", start);
        if (end < 0) throw new AssertionError("Unterminated channel case: " + name);
        return plugin.substring(start, end + "break;".length());
    }

    private static final String HARNESS = """
        import java.util.ArrayList;
        import java.util.HashMap;
        import java.util.List;
        import java.util.Locale;
        import java.util.Objects;

        public class ParkedVideoOutput {
            // FALLBACK_FIELD

            static int assertions;

            static class SurfaceTextureEntry {
                int releases;
                final SurfaceTexture texture = new SurfaceTexture();
                void release() { releases++; }
                SurfaceTexture surfaceTexture() { return texture; }
            }
            static class SurfaceTexture {
                boolean listenerAttached = true;
                void setOnFrameAvailableListener(Object listener) { listenerAttached = listener != null; }
            }
            static class Surface {
                int releases;
                void release() { releases++; }
            }
            static class GlobalRef {
                final List<Long> deleted = new ArrayList<>();
                void invoke(Object target, long handle) { deleted.add(handle); }
            }
            static class Handler {
                // The upstream code builds a fresh Handler per call, so the fake
                // queues on the class: that is the main looper's one queue.
                static final List<Runnable> scheduled = new ArrayList<>();
                static final List<Long> delays = new ArrayList<>();
                Handler() {}
                Handler(Looper mainLooper) {}
                Runnable postDelayed(Runnable task, long delay) {
                    scheduled.add(task);
                    delays.add(delay);
                    return task;
                }
                void removeCallbacks(Runnable task) { scheduled.remove(task); }
                static void reset() { scheduled.clear(); delays.clear(); }
            }
            static class Looper { static Looper getMainLooper() { return new Looper(); } }
            static class Log { static int i(String tag, String message) { return 0; } }

            static class VideoOutput {
                final Object lock = new Object();
                final SurfaceTextureEntry surfaceTextureEntry = new SurfaceTextureEntry();
                final GlobalRef deleteGlobalObjectRef = new GlobalRef();
                Surface surface = new Surface();
                long wid = 71;
                Runnable pendingRelease;
                boolean nativeReleased = false;

                VideoOutput(long handle, Object channel, Object registry) {}

                // OUTPUT_METHODS
            }

            static class VideoOutputManager {
                final HashMap<Long, VideoOutput> videoOutputs = new HashMap<>();
                final HashMap<Long, VideoOutput> pendingReleases = new HashMap<>();
                final Object lock = new Object();
                final Object channelReference = new Object();
                final Object textureRegistryReference = new Object();

                // MANAGER_METHODS
            }

            static void require(boolean value, String message) {
                assertions++;
                if (!value) throw new AssertionError(message);
            }

            public static void main(String[] args) {
                // retireNativeObjects() clears the field, so hold the window
                // references the assertions are about.
                // 1. dispose() must not retire anything the core may still use.
                Handler.reset();
                VideoOutputManager manager = new VideoOutputManager();
                VideoOutput output = manager.create(5L);
                Surface outputSurface = output.surface;
                manager.dispose(5L);
                require(!output.surfaceTextureEntry.texture.listenerAttached,
                    "Frame callback survived dispose");
                require(output.surfaceTextureEntry.releases == 0, "Texture entry released during dispose");
                require(outputSurface.releases == 0, "Surface released while libmpv may still own it");
                require(output.deleteGlobalObjectRef.deleted.isEmpty(), "JNI reference deleted during dispose");
                require(Handler.scheduled.size() == 1, "dispose must park exactly one fallback release");
                require(Handler.delays.get(0) > 5000L,
                    "Fallback must outlive the core's five-second destroy timer");

                // 2. The owner's confirmation retires all three, exactly once.
                manager.releaseNative(5L);
                require(output.surfaceTextureEntry.releases == 1, "Texture entry was not retired");
                require(outputSurface.releases == 1, "Surface was not retired");
                require(output.surface == null, "Retired surface remained attached");
                require(output.deleteGlobalObjectRef.deleted.equals(List.of(71L)),
                    "JNI reference was not retired once");
                require(Handler.scheduled.isEmpty(), "Fallback task was not cancelled");
                require(manager.videoOutputs.isEmpty() && manager.pendingReleases.isEmpty(),
                    "Retired output stayed reachable");

                // 3. A recycled mpv_handle address must not displace a parked output.
                manager = new VideoOutputManager();
                VideoOutput first = manager.create(9L);
                manager.dispose(9L);
                VideoOutput second = manager.create(9L);
                Surface liveSurface = second.surface;
                require(first != second, "Recycled handle reused the disposed output");
                require(liveSurface.releases == 0 && second.pendingRelease == null,
                    "New output was disturbed by the parked one");
                manager.releaseNative(9L);
                require(first.surface == null || first.surface.releases == 1,
                    "Parked output was not retired by handle");
                require(liveSurface.releases == 0, "Live output was retired by a recycled handle");
                require(manager.videoOutputs.get(9L) == second, "Live output lost from the map");
                manager.dispose(9L);
                manager.releaseNative(9L);
                require(liveSurface.releases == 1, "Replaced output was never retired");

                // 4. Only the fallback fires: a late confirmation must not double-retire.
                manager = new VideoOutputManager();
                Handler.reset();
                VideoOutput abandoned = manager.create(11L);
                Surface abandonedSurface = abandoned.surface;
                manager.dispose(11L);
                Runnable fallback = Handler.scheduled.get(0);
                Handler.reset();
                fallback.run();
                require(abandoned.surfaceTextureEntry.releases == 1
                    && abandonedSurface.releases == 1
                    && abandoned.deleteGlobalObjectRef.deleted.size() == 1,
                    "Fallback did not retire the parked objects");
                manager.releaseNative(11L);
                require(abandonedSurface.releases == 1, "Fallback and confirmation both retired");
                manager.dispose(11L);
                require(manager.pendingReleases.isEmpty(), "Retired output was parked again");

                // 5. Unknown handles and repeated confirmation are inert.
                manager.releaseNative(404L);
                VideoOutput repeated = manager.create(13L);
                Surface repeatedSurface = repeated.surface;
                manager.dispose(13L);
                manager.releaseNative(13L);
                manager.releaseNative(13L);
                require(repeatedSurface.releases == 1, "Repeated confirmation retired twice");
                System.out.println("media_kit_video surface release regression: "
                    + assertions + " assertions passed");
            }
        }
        """;
}
