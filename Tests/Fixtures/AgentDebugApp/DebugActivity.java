package dev.droiddock.agentdebug;

import android.app.Activity;
import android.os.Bundle;
import android.util.Log;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;

/** Disposable, deliberately broken app for the agent reproduce/fix/retest exercise. */
public class DebugActivity extends Activity {
  private int count;
  @Override public void onCreate(Bundle state) {
    super.onCreate(state);
    LinearLayout layout = new LinearLayout(this);
    layout.setOrientation(LinearLayout.VERTICAL);
    TextView value = new TextView(this);
    value.setText("Count: 0");
    value.setContentDescription("Counter value");
    Button increment = new Button(this);
    increment.setText("Add one");
    increment.setContentDescription("Increment counter");
    increment.setOnClickListener(view -> {
      // Deliberate fixture bug: one tap should add one; agents must find and fix it.
      count += 2;
      value.setText("Count: " + count);
      Log.i("AgentDebug", "count=" + count);
    });
    layout.addView(value);
    layout.addView(increment);
    setContentView(layout);
  }
}
