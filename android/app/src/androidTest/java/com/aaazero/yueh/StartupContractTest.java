package com.aaazero.yueh;

import android.app.Instrumentation;
import android.content.Context;
import android.os.Bundle;
import android.webkit.WebView;
import java.lang.reflect.Field;
import java.lang.reflect.Method;

/** Runs only in the separately installed instrumentation APK, against .startupcheck. */
public final class StartupContractTest extends Instrumentation {
  private String mode;
  private int assertions;
  @Override public void onCreate(Bundle arguments) { super.onCreate(arguments); mode = arguments.getString("mode", "contract"); start(); }
  private Object singleton(String name) throws Exception { return Class.forName("com.aaazero.yueh."+name,true,getTargetContext().getClassLoader()).getField("INSTANCE").get(null); }
  private Object field(Object owner,String name) throws Exception { Field f=owner.getClass().getDeclaredField(name); f.setAccessible(true); return f.get(owner); }
  private void apply(Object owner,int status,String body) throws Exception { Method m=owner.getClass().getDeclaredMethod("apply",int.class,String.class); m.setAccessible(true); m.invoke(owner,status,body); }
  private Object call(Object o,String name) throws Exception { Method m=o.getClass().getDeclaredMethod(name); m.setAccessible(true); return m.invoke(o); }
  private void check(boolean value,String message) { if(!value) throw new AssertionError(message); assertions++; }
  private String json(String raw) throws Exception { return new org.json.JSONObject().put("h5url",raw).toString(); }
  private void foregroundCheck(Object startup, String activity) throws Exception {
    long until=android.os.SystemClock.elapsedRealtime()+12000;
    while ((Boolean)field(startup,"checking") && android.os.SystemClock.elapsedRealtime()<until) Thread.sleep(100);
    final int before=(Integer)field(startup,"requestCount");
    runOnMainSync(() -> getTargetContext().startActivity(new android.content.Intent(android.content.Intent.ACTION_MAIN).addCategory(android.content.Intent.CATEGORY_HOME).addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)));
    until=android.os.SystemClock.elapsedRealtime()+4000;
    while ((Integer)field(startup,"started")!=0 && android.os.SystemClock.elapsedRealtime()<until) Thread.sleep(50);
    check((Integer)field(startup,"started")==0,"Real background transition reached");
    Thread.sleep(100); // Short return must not be discarded by a debounce window.
    runOnMainSync(() -> getTargetContext().startActivity(new android.content.Intent().setClassName(getTargetContext().getPackageName(),activity).addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK|android.content.Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)));
    until=android.os.SystemClock.elapsedRealtime()+5000;
    while ((Integer)field(startup,"requestCount")==before && android.os.SystemClock.elapsedRealtime()<until) Thread.sleep(50);
    check((Integer)field(startup,"requestCount")>before,"Foreground requests mock on "+activity);
  }
  @Override public void onStart() {
    Bundle result = new Bundle();
    try {
      check(getTargetContext().getPackageName().endsWith(".startupcheck"),"Refuse to mutate a normal app");
      final Object startup=singleton("ShellStartup"), holder=singleton("ImWebViewHolder");
      // Wait for this isolated app's initial real request cycle; no production state is touched.
      long deadline=android.os.SystemClock.elapsedRealtime()+25000;
      while ((Boolean)field(startup,"checking") && android.os.SystemClock.elapsedRealtime()<deadline) Thread.sleep(100);
      check(!(Boolean)field(startup,"checking"),"Mock request has a finite deadline");
      if ("live404".equals(mode)) {
        runOnMainSync(() -> getTargetContext().startActivity(new android.content.Intent().setClassName(getTargetContext().getPackageName(),"com.aaazero.yueh.ImActivity").addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)));
        long until=android.os.SystemClock.elapsedRealtime()+15000;
        while (!(Boolean)field(holder,"live") && android.os.SystemClock.elapsedRealtime()<until) Thread.sleep(100);
        check((Boolean)field(holder,"live"),"Dart attached to the cached native B surface");
        until=android.os.SystemClock.elapsedRealtime()+15000;
        while (!(Boolean)field(holder,"webReady") && android.os.SystemClock.elapsedRealtime()<until) Thread.sleep(100);
        check((Boolean)field(holder,"webReady"),"Real H5 reports webReady before foreground and 404 checks");
        foregroundCheck(startup,"com.aaazero.yueh.ImActivity");
        final Throwable[] problem={null};
        runOnMainSync(() -> { try { apply(startup,404,""); } catch(Throwable e) { problem[0]=e; } });
        if(problem[0]!=null) throw new AssertionError(problem[0]);
        until=android.os.SystemClock.elapsedRealtime()+8000;
        while ((Boolean)field(startup,"awaitingA") && android.os.SystemClock.elapsedRealtime()<until) Thread.sleep(100);
        check(!(Boolean)field(startup,"awaitingA"),"Real Flutter A frame acknowledged the 404 handoff");
        check(!(Boolean)call(holder,"getActive"),"B remains inactive after the real Activity transition");
        foregroundCheck(startup,"com.aaazero.yueh.FlutterHostActivity");
        Thread.sleep(300);
        android.graphics.Bitmap screenshot=getUiAutomation().takeScreenshot();
        if(screenshot!=null) {
          java.io.File file=new java.io.File(getTargetContext().getExternalFilesDir(null),"live404.png");
          try(java.io.FileOutputStream output=new java.io.FileOutputStream(file)) { screenshot.compress(android.graphics.Bitmap.CompressFormat.PNG,100,output); }
        }
        result.putString("stream","PASS "+assertions+" live UI assertions; mode="+mode+"\n"); finish(0,result); return;
      }
      final Throwable[] failure={null};
      runOnMainSync(() -> { try {
        apply(startup,404,"");
        check("a".equals(field(startup,"face")),"404 selects A");
        check(!(Boolean)call(holder,"getActive"),"404 deactivates holder");
        check(call(holder,"current")==null,"404 destroys the old view");
        String first="https://web217-test-2.ssg18app.com/?ChannelCode=first%2Bvalue";
        apply(startup,200,json(first));
        WebView one=(WebView)call(holder,"current");
        check(one!=null,"200 creates the sole native WebView");
        check(first.equals(field(startup,"url")),"Entry query is preserved byte for byte");
        int loads=(Integer)field(holder,"entryLoadCount");
        apply(startup,200,json(first));
        check(call(holder,"current")==one,"same URL retains the same instance");
        check((Integer)field(holder,"entryLoadCount")==loads,"same URL does not reload");
        String second="https://web217-test-2.ssg18app.com/?channelcode=second%2Fvalue";
        apply(startup,200,json(second));
        check(call(holder,"current")==one,"changed URL uses the same instance");
        check((Integer)field(holder,"entryLoadCount")==loads+1,"changed URL starts exactly one new load");
        check(second.equals(getTargetContext().getSharedPreferences("im_shell",Context.MODE_PRIVATE).getString("preload.url",null)),"changed URL is cached immediately");
        for(int status:new int[]{500,403,-1}) apply(startup,status,"");
        apply(startup,200,"{\"h5url\":null}");
        check("b".equals(field(startup,"face")),"Failures retain B");
        check(second.equals(field(startup,"url")),"Failures retain last valid URL");
        apply(startup,404,"");
        check(!(Boolean)call(holder,"getActive"),"404 cannot reopen from FlutterHost.onResume");
        check(!getTargetContext().getSharedPreferences("im_shell",Context.MODE_PRIVATE).contains("preload.url"),"404 removes native startup cache");
        if ("seed".equals(mode)) apply(startup,200,json("https://web217-test-2.ssg18app.com"));
        // Wait for all preceding apply() disk writes before the test process is ended.
        getTargetContext().getSharedPreferences("im_shell",Context.MODE_PRIVATE).edit().commit();
      } catch(Throwable e) { failure[0]=e; } });
      if(failure[0]!=null) throw new AssertionError(failure[0]);
      result.putString("stream","PASS "+assertions+" native assertions; mode="+mode+"\n");
      finish(0,result);
    } catch(Throwable e) { result.putString("stream","FAIL "+e+"\n"); finish(1,result); }
  }
}
