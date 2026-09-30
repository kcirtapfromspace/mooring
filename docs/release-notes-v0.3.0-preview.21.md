# MacLink 0.3.0 preview 21 — The pointer lines up, and the menu bar is yours

Installed copies of preview 6 or later update to this version by themselves when no session is connected.

## Clicks land at the pointer's tip

Since preview 10, while you controlled the sharing Mac, clicks landed above the pointer you saw, and a little to the right. With the arrow, the difference was about 18 points. The pointer also looked smaller than usual.

The sharing Mac sent its pointer image drawn at half size, in the bottom-left corner of the image. The point where clicks land was sent correctly, so the viewing Mac drew the pointer below it. Now the pointer is drawn full size, where it belongs. The arrow's tip, the I-beam's center and the hand's fingertip are where clicks land.

The screen size and click mapping were already exact, including with **Match Shared Screen to This Mac**. Only the pointer's picture was off.

This fix is on the sharing Mac. Update it to preview 21.

## Reach the sharing Mac's menu bar

In full screen, moving the pointer to the top of the screen used to slide down this Mac's menu bar and the viewer's title bar. They covered the sharing Mac's menu bar, so its menus couldn't be clicked.

Now, while you control the sharing Mac, the viewer's full screen hides this Mac's menu bar and Dock. The top edge belongs to the sharing Mac: its Apple menu, app menus and menu bar icons work as they would locally.

To get back to this Mac:

- click **Exit Full Screen** in the viewer's status bar, at the bottom of the screen;
- press **⌃⌘F**, which now leaves full screen. Before, while you controlled the sharing Mac, it went to the sharing Mac instead;
- swipe between Spaces on the trackpad to show this Mac's desktop, leaving the viewer in full screen.

A view-only session keeps the usual behavior, since the sharing Mac's menus can't be clicked anyway. The choice is made when the viewer enters full screen. If control is turned on or off during a session, leave and re-enter full screen to switch.

This change is on the viewing Mac. Update it to preview 21.

## Validation

Local validation passed with the full suite. A new session test draws a known shape into a pointer image and checks its pixels as sent and after the viewer rebuilds the pointer. It fails with the old drawing order. An in-process check confirmed that ⌃⌘F reached no full-screen handler before and reaches the new **View → Enter Full Screen** item now. The suite doesn't enter full screen, so the menu bar behavior is checked on the two Macs.

Apple silicon and macOS 14 or later. Developer ID signed, notarized and stapled. Published to the public update feed. All CI and builds run on the local host; GitHub Actions is disabled on both repositories.
