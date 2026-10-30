package com.cloudwebrtc.webrtc;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotEquals;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;
import static org.junit.Assert.fail;

import org.junit.Test;

/**
 * Iris §7.117 item 1 (S-7 blocker): receive endpoints are keyed by the transceiver mid, never by the receiver id —
 * libwebrtc takes that id from the remote msid track id and lets it collide across m-sections. The same id on the
 * same mid is a re-sighting (transceiver reuse, 8p1): same endpoint, no event. The same id on another mid is a
 * DUPLICATE: an event, and the lookup by id refuses (null) from then on. 8c: the leg_index range check.
 */
public class FlutterSFrameReceiverRegistryTest {
  @Test
  public void sameIdSameMidIsTheSameEndpointAndNoEvent() {
    FlutterSFrame.ReceiverRegistry r = new FlutterSFrame.ReceiverRegistry();
    FlutterSFrame.ReceiverRegistry.Admission first = r.admit("pc1", "TR_a", "0");
    assertEquals("pc1/recv/0", first.endpoint);
    assertFalse(first.duplicate);
    FlutterSFrame.ReceiverRegistry.Admission again = r.admit("pc1", "TR_a", "0");
    assertEquals("pc1/recv/0", again.endpoint);
    assertFalse(again.duplicate);
    assertEquals("pc1/recv/0", r.endpointOf("pc1", "TR_a"));
  }

  @Test
  public void sameIdOnAnotherMidIsADuplicateAndTheLookupRefuses() {
    FlutterSFrame.ReceiverRegistry r = new FlutterSFrame.ReceiverRegistry();
    r.admit("pc1", "TR_a", "0");
    FlutterSFrame.ReceiverRegistry.Admission dup = r.admit("pc1", "TR_a", "1");
    assertTrue(dup.duplicate);
    assertEquals("pc1/recv/1", dup.endpoint); // the duplicate still gets its own (unbound) transformer
    assertEquals("pc1/recv/0", dup.firstEndpoint);
    assertNull("ambiguous: refuse", r.endpointOf("pc1", "TR_a"));
    assertTrue(r.isAmbiguous("pc1", "TR_a"));
    assertTrue("stays ambiguous on a re-sighting of the first mid", r.admit("pc1", "TR_a", "0").duplicate);
    assertNull(r.endpointOf("pc1", "TR_a"));
  }

  @Test
  public void distinctIdsAndDistinctPeerConnectionsDoNotInterfere() {
    FlutterSFrame.ReceiverRegistry r = new FlutterSFrame.ReceiverRegistry();
    r.admit("pc1", "TR_a", "0");
    assertFalse(r.admit("pc1", "TR_b", "1").duplicate);
    assertFalse("the same id on ANOTHER peer connection is that connection's business", r.admit("pc2", "TR_a", "0").duplicate);
    assertEquals("pc1/recv/0", r.endpointOf("pc1", "TR_a"));
    assertEquals("pc1/recv/1", r.endpointOf("pc1", "TR_b"));
    assertEquals("pc2/recv/0", r.endpointOf("pc2", "TR_a"));
    assertNull("never seen", r.endpointOf("pc1", "TR_zzz"));
  }

  @Test
  public void noMidMeansAFreshUuidEndpoint() {
    FlutterSFrame.ReceiverRegistry r = new FlutterSFrame.ReceiverRegistry();
    FlutterSFrame.ReceiverRegistry.Admission a = r.admit("pc1", "TR_a", null);
    assertTrue(a.endpoint.startsWith("pc1/recv/"));
    assertNotEquals("pc1/recv/null", a.endpoint);
    assertEquals(a.endpoint, r.endpointOf("pc1", "TR_a"));
  }

  @Test
  public void legIndexIsRangeCheckedBeforeTheCast() {
    assertEquals(-1, FlutterSFrame.legIndexArg(-1L));
    assertEquals(1, FlutterSFrame.legIndexArg(1));
    assertEquals(0xFFFF, FlutterSFrame.legIndexArg(65535L));
    for (Object bad : new Object[] {0, -2, 0x10000, 0x10007L, 70000, Integer.MAX_VALUE, 4294967303L}) {
      try {
        FlutterSFrame.legIndexArg(bad);
        fail("8c: " + bad + " must be refused, not truncated");
      } catch (IllegalArgumentException expected) {
        // bindLegFailed on the channel
      }
    }
  }
}
