package com.cloudwebrtc.webrtc;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;
import static org.junit.Assert.fail;

import java.util.HashMap;
import java.util.Map;

import org.junit.Before;
import org.junit.Test;

/**
 * C182 S-8 (rulings Q5/Q6): once a key store was selected for auto-attach, "nothing selected" must attach the
 * key-less sentinel (everything drops) to every new sender/receiver, never nothing (= media in clear); a second store
 * cannot be selected while one is.
 */
public class FlutterSFrameAutoAttachTest {
  private final Map<String, Object> live = new HashMap<>();

  @Before
  public void freshProcess() {
    FlutterSFrame.AutoAttach.disarmForTest();
    FlutterSFrame.autoAttach.select(null, live);
    live.clear();
  }

  @Test
  public void neverArmedAttachesNothing() {
    FlutterSFrame.AutoAttach a = new FlutterSFrame.AutoAttach();
    assertNull(a.target(live)); // stock flutter-webrtc behaviour until a call selects a store
    a.select(null, live);
    assertNull(a.target(live));
    assertFalse(FlutterSFrame.AutoAttach.armed());
  }

  @Test
  public void afterTheFirstSelectionNothingSelectedMeansTheSentinel() {
    FlutterSFrame.AutoAttach a = new FlutterSFrame.AutoAttach();
    live.put("call-1", new Object());
    a.select("call-1", live);
    assertEquals("call-1", a.target(live));
    a.select(null, live); // autoAttach(false) at the end of the call
    assertEquals(FlutterSFrame.SENTINEL_ID, a.target(live));
    assertTrue(FlutterSFrame.AutoAttach.armed());
  }

  @Test
  public void disposingTheSelectedStoreHandsOverToTheSentinel() {
    FlutterSFrame.AutoAttach a = new FlutterSFrame.AutoAttach();
    live.put("call-1", new Object());
    a.select("call-1", live);
    live.remove("call-1");
    assertEquals(FlutterSFrame.SENTINEL_ID, a.target(live)); // even before forget(): a dead store never attaches
    a.forget("call-1");
    assertNull(a.selected());
    assertEquals(FlutterSFrame.SENTINEL_ID, a.target(live));
  }

  @Test
  public void theLatchOutlivesThePluginInstance() {
    live.put("call-1", new Object());
    new FlutterSFrame.AutoAttach().select("call-1", live);
    FlutterSFrame.AutoAttach next = new FlutterSFrame.AutoAttach(); // a new engine in the same process
    assertEquals(FlutterSFrame.SENTINEL_ID, next.target(live)); // Q5: armed for the life of the process
  }

  /**
   * Iris §7.117 item 3: the registry is process-wide. A second engine (a second FlutterSFrame) initialised after
   * engine 1 selected a store finds that selection as its hook target, and its own selection is refused (Q6).
   */
  @Test
  public void theRegistryIsProcessWideAcrossEngines() {
    FlutterSFrame engine1 = new FlutterSFrame(null);
    live.put("call-1", new Object());
    FlutterSFrame.autoAttach.select("call-1", live);
    FlutterSFrame engine2 = new FlutterSFrame(null); // a second engine in the same process
    assertEquals("call-1", FlutterSFrame.autoAttach.target(live)); // engine 1's hooks still reach its store
    live.put("call-2", new Object());
    try {
      FlutterSFrame.autoAttach.select("call-2", live); // engine 2's own call plane
      fail("Q6: refused while engine 1's store is selected");
    } catch (IllegalStateException expected) {
      // ok
    }
    assertEquals("call-1", FlutterSFrame.autoAttach.target(live));
    FlutterSFrame.autoAttach.select(null, live);
    assertTrue(engine1 != engine2);
  }

  @Test
  public void aSecondStoreIsRefusedWhileOneIsSelected() {
    FlutterSFrame.AutoAttach a = new FlutterSFrame.AutoAttach();
    live.put("call-1", new Object());
    live.put("call-2", new Object());
    a.select("call-1", live);
    a.select("call-1", live); // the same one again: fine
    try {
      a.select("call-2", live);
      fail("Q6: a second store must be refused while call-1 is selected");
    } catch (IllegalStateException expected) {
      // ok
    }
    assertEquals("call-1", a.target(live));
    a.select(null, live); // the first call ends
    a.select("call-2", live); // the next call may select its store
    assertEquals("call-2", a.target(live));
  }
}
