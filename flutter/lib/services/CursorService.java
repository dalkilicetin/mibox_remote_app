package com.aircursor;

import android.app.Service;
import android.content.Intent;
import android.graphics.PixelFormat;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.util.DisplayMetrics;
import android.util.Log;
import android.view.Gravity;
import android.view.WindowManager;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.io.PrintWriter;
import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;

import org.json.JSONObject;

public class CursorService extends Service {

    private static final String TAG = "AirCursor";
    private static final int PORT = 9876;

    // UDP discovery: iPhone bu porta broadcast atar, biz cevap veririz
    private static final int UDP_DISCOVERY_PORT = 9877;
    private static final String DISCOVERY_MAGIC = "AIRCURSOR_DISCOVER";

    // Android TV'nin standart portları — discovery response'da bildirilir
    // TV bu portları her zaman açık tutar (Android TV sistemi)
    private int atvPairingPort = 6467;
    private int atvRemotePort  = 6466;

    private WindowManager wm;
    private CursorView cursorView;
    private WindowManager.LayoutParams params;
    private Handler mainHandler;
    private int screenW = 1920;
    private int screenH = 1080;
    private volatile boolean running = true;

    private volatile int realX = 960;
    private volatile int realY = 540;

    @Override
    public void onCreate() {
        super.onCreate();
        mainHandler = new Handler(Looper.getMainLooper());
        setupOverlay();
        // Gerçek ATV portlarını bul (açık port taraması)
        detectAtvPorts();
        startSocketServer();
        startUdpDiscovery();
        Log.i(TAG, "CursorService started. TCP:" + PORT
            + " UDP:" + UDP_DISCOVERY_PORT
            + " ATV pairing:" + atvPairingPort
            + " ATV remote:" + atvRemotePort);
    }

    // Android TV'nin gerçek portlarını tespit et
    private void detectAtvPorts() {
        new Thread(() -> {
            int[] pairingCandidates = {6467, 6468, 7676};
            int[] remoteCandidates  = {6466, 6468, 7675};

            // localhost'ta açık portları dene — TV'nin kendi portları
            for (int port : pairingCandidates) {
                try {
                    Socket s = new Socket("127.0.0.1", port);
                    s.close();
                    atvPairingPort = port;
                    break;
                } catch (Exception ignored) {}
            }
            for (int port : remoteCandidates) {
                try {
                    Socket s = new Socket("127.0.0.1", port);
                    s.close();
                    atvRemotePort = port;
                    break;
                } catch (Exception ignored) {}
            }
            Log.i(TAG, "ATV ports detected — pairing:" + atvPairingPort + " remote:" + atvRemotePort);
        }).start();
    }

    // UDP discovery server — iPhone broadcast'ine cevap ver
    private void startUdpDiscovery() {
        new Thread(() -> {
            try (DatagramSocket udpSocket = new DatagramSocket(UDP_DISCOVERY_PORT)) {
                udpSocket.setBroadcast(true);
                Log.i(TAG, "UDP discovery listening on port " + UDP_DISCOVERY_PORT);
                byte[] buf = new byte[256];
                while (running) {
                    DatagramPacket packet = new DatagramPacket(buf, buf.length);
                    udpSocket.receive(packet);
                    String msg = new String(packet.getData(), 0, packet.getLength()).trim();
                    if (DISCOVERY_MAGIC.equals(msg)) {
                        // Cevap: tüm port bilgilerini gönder
                        String response = "{" +
                            "\"service\":\"aircursor\"," +
                            "\"cursorPort\":" + PORT + "," +
                            "\"atvPairingPort\":" + atvPairingPort + "," +
                            "\"atvRemotePort\":" + atvRemotePort + "," +
                            "\"w\":" + screenW + "," +
                            "\"h\":" + screenH +
                        "}";
                        byte[] respBytes = response.getBytes();
                        DatagramPacket resp = new DatagramPacket(
                            respBytes, respBytes.length,
                            packet.getAddress(), packet.getPort()
                        );
                        udpSocket.send(resp);
                        Log.i(TAG, "Discovery response sent to " + packet.getAddress());
                    }
                }
            } catch (Exception e) {
                if (running) Log.e(TAG, "UDP discovery error: " + e.getMessage());
            }
        }).start();
    }

    private void setupOverlay() {
        wm = (WindowManager) getSystemService(WINDOW_SERVICE);
        DisplayMetrics dm = new DisplayMetrics();
        wm.getDefaultDisplay().getMetrics(dm);
        screenW = dm.widthPixels;
        screenH = dm.heightPixels;
        realX = screenW / 2;
        realY = screenH / 2;
        cursorView = new CursorView(this);
        int type = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
            ? WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
            : WindowManager.LayoutParams.TYPE_PHONE;
        params = new WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            type,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
                | WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
                | WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT
        );
        params.gravity = Gravity.TOP | Gravity.LEFT;
        params.x = realX;
        params.y = realY;
        wm.addView(cursorView, params);
    }

    private void startSocketServer() {
        new Thread(() -> {
            try (ServerSocket ss = new ServerSocket(PORT)) {
                while (running) {
                    try {
                        Socket client = ss.accept();
                        handleClient(client);
                    } catch (Exception e) {
                        if (running) Log.w(TAG, "Client error: " + e.getMessage());
                    }
                }
            } catch (Exception e) {
                Log.e(TAG, "Server error: " + e.getMessage());
            }
        }).start();
    }

    private void handleClient(final Socket client) {
        new Thread(() -> {
            try {
                BufferedReader reader = new BufferedReader(
                    new InputStreamReader(client.getInputStream()));
                final PrintWriter writer = new PrintWriter(client.getOutputStream(), true);

                // Connect response'a ATV portlarını ekle
                writer.println("{" +
                    "\"status\":\"connected\"," +
                    "\"w\":" + screenW + "," +
                    "\"h\":" + screenH + "," +
                    "\"x\":" + realX + "," +
                    "\"y\":" + realY + "," +
                    "\"atvPairingPort\":" + atvPairingPort + "," +
                    "\"atvRemotePort\":" + atvRemotePort +
                "}");

                String line;
                while ((line = reader.readLine()) != null && running) {
                    processCommand(line.trim(), writer);
                }
            } catch (Exception e) {
                Log.d(TAG, "Client disconnected");
            } finally {
                try { client.close(); } catch (Exception ignored) {}
            }
        }).start();
    }

    private void moveCursor(int x, int y) {
        realX = Math.max(0, Math.min(x, screenW - 60));
        realY = Math.max(0, Math.min(y, screenH - 60));
        params.x = realX;
        params.y = realY;
        wm.updateViewLayout(cursorView, params);
    }

    private void injectSwipe(int x1, int y1, int x2, int y2, int durationMs) {
        new Thread(() -> {
            try {
                Runtime.getRuntime().exec(new String[]{
                    "input", "touchscreen", "swipe",
                    String.valueOf(x1), String.valueOf(y1),
                    String.valueOf(x2), String.valueOf(y2),
                    String.valueOf(durationMs)
                });
            } catch (Exception e) {
                Log.w(TAG, "Swipe error: " + e.getMessage());
            }
        }).start();
    }

    private void injectText(String text) {
        new Thread(() -> {
            try {
                String escaped = text.replace(" ", "%s");
                Runtime.getRuntime().exec(new String[]{"input", "text", escaped});
            } catch (Exception e) {
                Log.w(TAG, "Text error: " + e.getMessage());
            }
        }).start();
    }

    private void injectKeyEvent(int keyCode) {
        new Thread(() -> {
            try {
                Runtime.getRuntime().exec(new String[]{
                    "input", "keyevent", String.valueOf(keyCode)
                });
            } catch (Exception e) {
                Log.w(TAG, "Key error: " + e.getMessage());
            }
        }).start();
    }

    private void processCommand(String json, PrintWriter writer) {
        try {
            JSONObject obj = new JSONObject(json);
            String type = obj.getString("type");

            if (type.equals("move")) {
                int dx = obj.optInt("dx", 0);
                int dy = obj.optInt("dy", 0);
                int nx = Math.max(0, Math.min(realX + dx, screenW - 60));
                int ny = Math.max(0, Math.min(realY + dy, screenH - 60));
                mainHandler.post(() -> moveCursor(nx, ny));
                writer.println("{\"x\":" + nx + ",\"y\":" + ny + "}");

            } else if (type.equals("tap")) {
                mainHandler.post(() -> cursorView.showClick());
                final int tapX = realX, tapY = realY;
                mainHandler.post(() -> {
                    AirCursorAccessibility a11y = AirCursorAccessibility.getInstance();
                    if (a11y != null) a11y.performTap(tapX, tapY);
                });
                writer.println("{\"tap\":true,\"x\":" + realX + ",\"y\":" + realY + "}");

            } else if (type.equals("hide")) {
                mainHandler.post(() -> cursorView.setVisibility(android.view.View.INVISIBLE));
                writer.println("{\"hidden\":true}");

            } else if (type.equals("show")) {
                mainHandler.post(() -> cursorView.setVisibility(android.view.View.VISIBLE));
                writer.println("{\"hidden\":false}");

            } else if (type.equals("scroll_mode")) {
                int mode = obj.optInt("mode", 0);
                mainHandler.post(() -> cursorView.setScrollMode(mode));
                writer.println("{\"scroll_mode\":" + mode + "}");

            } else if (type.equals("text")) {
                String value = obj.optString("value", "");
                if (!value.isEmpty()) {
                    injectText(value);
                    writer.println("{\"text\":true}");
                }

            } else if (type.equals("key")) {
                int code = obj.optInt("code", 0);
                if (code > 0) {
                    injectKeyEvent(code);
                    writer.println("{\"key\":" + code + "}");
                }

            } else if (type.equals("swipe")) {
                int x1 = obj.optInt("x1", screenW / 2);
                int y1 = obj.optInt("y1", screenH / 2);
                int x2 = obj.optInt("x2", screenW / 2);
                int y2 = obj.optInt("y2", screenH / 2 - 200);
                int dur = obj.optInt("duration", 150);
                final int fx1=x1, fy1=y1, fx2=x2, fy2=y2, fdur=dur;
                mainHandler.post(() -> {
                    AirCursorAccessibility a11y = AirCursorAccessibility.getInstance();
                    if (a11y != null) a11y.performSwipe(fx1, fy1, fx2, fy2, fdur);
                    else injectSwipe(fx1, fy1, fx2, fy2, fdur);
                });
                writer.println("{\"swipe\":true}");
            }

        } catch (Exception e) {
            Log.w(TAG, "JSON error: " + json);
        }
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        return START_STICKY;
    }

    @Override
    public void onDestroy() {
        running = false;
        if (cursorView != null && wm != null) {
            try { wm.removeView(cursorView); } catch (Exception ignored) {}
        }
        super.onDestroy();
    }

    @Override
    public IBinder onBind(Intent intent) { return null; }
}
