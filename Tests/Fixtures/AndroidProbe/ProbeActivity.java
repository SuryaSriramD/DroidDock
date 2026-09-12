package dev.androidsimulator.probe;
import android.app.Activity;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.os.Bundle;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.view.View;
import android.widget.*;
import android.util.Log;
import android.view.MotionEvent;
import android.view.KeyEvent;
import android.view.WindowManager;
import java.util.UUID;

public class ProbeActivity extends Activity {
  private String session;
  private int touches;
  private int drags;
  private boolean animating = true;
  private View animation;
  private EditText input;
  private void event(String message) { Log.i("SimulatorProbe", "SESSION=" + session + " " + message); }
  @Override public void onCreate(Bundle state) {
    super.onCreate(state);
    getWindow().setFlags(WindowManager.LayoutParams.FLAG_FULLSCREEN, WindowManager.LayoutParams.FLAG_FULLSCREEN);
    session = getIntent().getStringExtra("session");
    if (session == null) session = "manual";
    LinearLayout layout = new LinearLayout(this); layout.setOrientation(LinearLayout.VERTICAL); layout.setPadding(40,40,40,40);
    layout.setBackgroundColor(Color.rgb(235,244,240));
    TextView heading = new TextView(this); heading.setText("Android Simulator verification"); heading.setTextSize(24); layout.addView(heading);
    EditText text = new EditText(this); text.setSingleLine(true); text.setHint("Keyboard verification"); text.setContentDescription("Probe text input"); layout.addView(text);
    input = text;
    Button button = new Button(this); button.setText("Verify touch"); button.setContentDescription("Probe touch button"); layout.addView(button);
    animation = new View(this) {
      Paint paint = new Paint(3);
      int moves;
      float startX;
      @Override protected void onDraw(Canvas canvas) {
        super.onDraw(canvas); float t = (System.nanoTime()/1000000L % 2000)/2000f;
        canvas.drawColor(Color.rgb(219,237,229));
        paint.setColor(Color.rgb(42,115,83)); canvas.drawCircle(60+t*(getWidth()-120),getHeight()/2f,45,paint);
        if (animating) postInvalidateOnAnimation();
      }
      @Override public boolean onTouchEvent(MotionEvent input) {
        switch(input.getActionMasked()) {
          case MotionEvent.ACTION_DOWN: moves = 0; startX = input.getX(); return true;
          case MotionEvent.ACTION_MOVE: moves++; return true;
          case MotionEvent.ACTION_UP:
            if(moves > 0 && Math.abs(input.getX()-startX) > getWidth()/4f) {
              drags++;
              event("DRAG_VERIFIED drags="+drags+" moves="+moves);
            }
            return true;
          case MotionEvent.ACTION_CANCEL: event("DRAG_CANCELLED"); return true;
        }
        return true;
      }
    };
    animation.setContentDescription("Probe animation and drag surface");
    layout.addView(animation,new LinearLayout.LayoutParams(-1,0,1));
    Button clipboardButton = new Button(this); clipboardButton.setText("Set test clipboard");
    clipboardButton.setContentDescription("Probe set clipboard button"); layout.addView(clipboardButton);
    TextView clipboardToken = new TextView(this); clipboardToken.setText("Clipboard test token: not set");
    clipboardToken.setTextSize(12); clipboardToken.setTypeface(android.graphics.Typeface.MONOSPACE);
    clipboardToken.setMinLines(2); clipboardToken.setMaxLines(2);
    clipboardToken.setContentDescription("Probe clipboard token"); layout.addView(clipboardToken);
    clipboardButton.setOnClickListener(new View.OnClickListener() { public void onClick(View v) {
      // Generate the value inside Android so host clipboard restore behavior
      // cannot supply the expected result. Never read or log an existing clip.
      ClipboardManager clipboard = getSystemService(ClipboardManager.class);
      if (clipboard == null) { clipboardToken.setText("Clipboard service unavailable"); event("CLIPBOARD_FAILED unavailable"); return; }
      String token = "ProbeClip-" + UUID.randomUUID().toString();
      try {
        clipboard.setPrimaryClip(ClipData.newPlainText("Android Simulator probe", token));
        clipboardToken.setText(token);
        event("CLIPBOARD_SET token=" + token);
      } catch (RuntimeException failure) {
        clipboardToken.setText("Could not set test clipboard");
        event("CLIPBOARD_FAILED type=" + failure.getClass().getSimpleName());
      }
    } });
    button.setOnClickListener(new View.OnClickListener() { public void onClick(View v) {
      touches++;
      button.setText("Input verified ("+touches+")");
      event("TOUCH_VERIFIED touches="+touches+" text="+text.getText());
    } });
    text.addTextChangedListener(new android.text.TextWatcher() {
      public void beforeTextChanged(CharSequence s,int a,int c,int f) {}
      public void onTextChanged(CharSequence s,int start,int before,int count) { event("TEXT="+s); }
      public void afterTextChanged(android.text.Editable e) {}
    });
    setContentView(layout);
    layout.getViewTreeObserver().addOnGlobalLayoutListener(new android.view.ViewTreeObserver.OnGlobalLayoutListener() {
      String previous = "";
      public void onGlobalLayout() {
        android.util.DisplayMetrics metrics = new android.util.DisplayMetrics();
        getWindowManager().getDefaultDisplay().getRealMetrics(metrics);
        int[] buttonPosition = new int[2]; button.getLocationOnScreen(buttonPosition);
        int[] textPosition = new int[2]; text.getLocationOnScreen(textPosition);
        int[] dragPosition = new int[2]; animation.getLocationOnScreen(dragPosition);
        int[] clipboardPosition = new int[2]; clipboardButton.getLocationOnScreen(clipboardPosition);
        String geometry = "GEOMETRY width="+metrics.widthPixels+" height="+metrics.heightPixels
          +" buttonX="+(buttonPosition[0]+button.getWidth()/2)+" buttonY="+(buttonPosition[1]+button.getHeight()/2)
          +" textX="+(textPosition[0]+text.getWidth()/2)+" textY="+(textPosition[1]+text.getHeight()/2)
          +" dragStartX="+(dragPosition[0]+animation.getWidth()/4)+" dragEndX="+(dragPosition[0]+animation.getWidth()*3/4)
          +" dragY="+(dragPosition[1]+animation.getHeight()/2)
          +" clipboardX="+(clipboardPosition[0]+clipboardButton.getWidth()/2)+" clipboardY="+(clipboardPosition[1]+clipboardButton.getHeight()/2);
        if (!geometry.equals(previous)) { event(geometry); previous = geometry; }
      }
    });
    event("CREATED");
  }
  @Override public boolean onKeyDown(int keyCode, KeyEvent event) {
    if (keyCode == KeyEvent.KEYCODE_F1) {
      animating = !animating;
      input.setCursorVisible(animating);
      animation.invalidate();
      event(animating ? "ANIMATION_RESUMED" : "ANIMATION_PAUSED");
      return true;
    }
    return super.onKeyDown(keyCode, event);
  }
}
