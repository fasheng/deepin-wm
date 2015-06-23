//
//  Copyright (C) 2014 Deepin, Inc.
//  Copyright (C) 2014 Tom Beckmann
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

using Clutter;
using Meta;

namespace Gala
{
	/**
	 * Container which controls the layout of a set of
	 * WindowClones. The WindowClones will be placed in rows and
	 * columns.
	 */
	public class DeepinWindowCloneFlowContainer : Actor
	{
		public signal void window_activated (Window window);
		public signal void window_selected (Window window);

		public int padding_top { get; set; default = 12; }
		public int padding_left { get; set; default = 12; }
		public int padding_right { get; set; default = 12; }
		public int padding_bottom { get; set; default = 12; }

		public bool overview_mode { get; construct; }

		bool opened;

		/**
		 * The window that is currently selected via keyboard shortcuts. It is not
		 * necessarily the same as the active window.
		 */
		DeepinWindowClone? current_window;

		public DeepinWindowCloneFlowContainer (bool overview_mode = false)
		{
			Object (overview_mode: overview_mode);
		}

		construct
		{
			opened = false;
			current_window = null;
		}

		/**
		 * Create a DeepinWindowClone for a MetaWindow and add it to the group
		 *
		 * @param window The window for which to create the DeepinWindowClone for
		 */
		public void add_window (Window window)
		{
			unowned Meta.Display display = window.get_display ();
			var children = get_children ();

			GLib.SList<unowned Meta.Window> windows = new GLib.SList<unowned Meta.Window> ();
			foreach (unowned Actor child in children) {
				unowned DeepinWindowClone tw = (DeepinWindowClone) child;
				windows.prepend (tw.window);
			}
			windows.prepend (window);
			windows.reverse ();

			var windows_ordered = display.sort_windows_by_stacking (windows);

			var new_window = new DeepinWindowClone (window, overview_mode);

			new_window.activated.connect (on_window_activated);
			new_window.destroy.connect (on_window_destroyed);
			new_window.request_reposition.connect (reflow);

			var added = false;
			unowned Meta.Window? target = null;
			foreach (unowned Meta.Window w in windows_ordered) {
				if (w != window) {
					target = w;
					continue;
				}
				break;
			}

			foreach (unowned Actor child in children) {
				unowned DeepinWindowClone tw = (DeepinWindowClone) child;
				if (target == tw.window) {
					insert_child_above (new_window, tw);
					added = true;
					break;
				}
			}

			// top most or no other children
			if (!added) {
				add_child (new_window);
			}

			reflow ();
		}

		/**
		 * Find and remove the DeepinWindowClone for a MetaWindow
		 */
		public void remove_window (Window window)
		{
			foreach (var child in get_children ()) {
				if (((DeepinWindowClone) child).window == window) {
					remove_child (child);
					break;
				}
			}

			reflow ();
		}

		void on_window_activated (DeepinWindowClone clone)
		{
			// TODO: restore state before selecting
			clone.select = false;
			window_activated (clone.window);
		}

		void on_window_destroyed (Actor actor)
		{
			var window = actor as DeepinWindowClone;
			if (window == null) {
				return;
			}

			window.destroy.disconnect (on_window_destroyed);
			window.activated.disconnect (on_window_activated);
			window.request_reposition.disconnect (reflow);

			Idle.add (() => {
				reflow ();
				return false;
			});
		}

		/**
		 * Sort the windows z-order by their actual stacking to make intersections
		 * during animations correct.
		 */
		public void restack_windows (Screen screen)
		{
			unowned Meta.Display display = screen.get_display ();
			var children = get_children ();

			GLib.SList<unowned Meta.Window> windows = new GLib.SList<unowned Meta.Window> ();
			foreach (unowned Actor child in children) {
				unowned DeepinWindowClone tw = (DeepinWindowClone) child;
				windows.prepend (tw.window);
			}

			var windows_ordered = display.sort_windows_by_stacking (windows);
			windows_ordered.reverse ();

			foreach (unowned Meta.Window window in windows_ordered) {
				var i = 0;
				foreach (unowned Actor child in children) {
					if (((DeepinWindowClone) child).window == window) {
						set_child_at_index (child, i);
						children.remove (child);
						i++;
						break;
					}
				}
			}
		}

		/**
		 * Recalculate the tiling positions of the windows and animate them to
		 * the resulting spots.
		 */
		public void reflow ()
		{
			if (!opened) {
				return;
			}

			var windows = new List<InternalUtils.TilableWindow?> ();
			foreach (var child in get_children ()) {
				unowned DeepinWindowClone window = (DeepinWindowClone) child;
#if HAS_MUTTER312
				windows.prepend ({ window.window.get_frame_rect (), window });
#else
				windows.prepend ({ window.window.get_outer_rect (), window });
#endif
			}

			if (windows.length () < 1) {
				return;
			}

			// TODO: sort windows
			// make sure the windows are always in the same order so the algorithm
			// doesn't give us different slots based on stacking order, which can lead
			// to windows flying around weirdly
			windows.sort ((a, b) => {
				var seq_a = ((DeepinWindowClone) a.id).window.get_stable_sequence ();
				var seq_b = ((DeepinWindowClone) b.id).window.get_stable_sequence ();
				return (int) (seq_b - seq_a);
			});

			Meta.Rectangle area = {
				padding_left,
				padding_top,
				(int)width - padding_left - padding_right,
				(int)height - padding_top - padding_bottom
			};

			var window_positions = InternalUtils.calculate_grid_placement (area, windows);

			foreach (var tilable in window_positions) {
				unowned DeepinWindowClone window = (DeepinWindowClone) tilable.id;
				if (!window.select) {
					tilable.rect = DeepinUtils.scale_rect_in_center (tilable.rect, 0.9f);
				}
				window.take_slot (tilable.rect);
			}
		}

		/**
		 * Change current selected window and call reflow to adjust
		 * windows size.
		 */
		void change_current_window (DeepinWindowClone? window, bool need_reflow = true)
		{
			if (window == null) {
				if (current_window != null) {
					current_window.select = false;
					current_window = null;
				}
			} else {
				if (current_window != window) {
					if (current_window != null) {
						current_window.select = false;
					}
					current_window = window;
				}
				current_window.select = true;
				window_selected (current_window.window);
			}

			if (need_reflow) {
				reflow ();
			}
		}

		/**
		 * Select the next window.
		 *
		 * @param backward The window order in which to looking for.
		 */
		public void select_window_by_order (bool backward)
		{
			if (get_n_children () < 1) {
				return;
			}

			if (current_window == null) {
				change_current_window ((DeepinWindowClone) get_child_at_index (0));
				return;
			}

			DeepinWindowClone next_window;
			if (backward) {
				next_window = (DeepinWindowClone) current_window.get_next_sibling ();
				if (next_window == null) {
					next_window = (DeepinWindowClone) get_first_child ();
				}
			} else {
				next_window = (DeepinWindowClone) current_window.get_previous_sibling ();
				if (next_window == null) {
					next_window = (DeepinWindowClone) get_last_child ();
				}
			}

			if (current_window != null) {
				current_window.select = false;
			}

			change_current_window (next_window);
		}

		/**
		 * Look for the next window in a direction and make this window the
		 * new current_window. Used for keyboard navigation.
		 *
		 * @param direction The MetaMotionDirection in which to search for windows for.
		 */
		public void select_window_by_direction (MotionDirection direction)
		{
			if (get_n_children () < 1) {
				return;
			}

			if (current_window == null) {
				change_current_window ((DeepinWindowClone) get_child_at_index (0));
				return;
			}

			var current_rect = current_window.slot;

			DeepinWindowClone? closest = null;
			foreach (var window in get_children ()) {
				if (window == current_window) {
					continue;
				}

				var window_rect = ((DeepinWindowClone) window).slot;

				switch (direction) {
					case MotionDirection.LEFT:
						if (window_rect.x > current_rect.x) {
							continue;
						}

						// test for vertical intersection
						if (window_rect.y + window_rect.height > current_rect.y
							&& window_rect.y < current_rect.y + current_rect.height) {

							if (closest == null
								|| closest.slot.x < window_rect.x) {
								closest = (DeepinWindowClone) window;
							}
						}
						break;
					case MotionDirection.RIGHT:
						if (window_rect.x < current_rect.x) {
							continue;
						}

						// test for vertical intersection
						if (window_rect.y + window_rect.height > current_rect.y
							&& window_rect.y < current_rect.y + current_rect.height) {

							if (closest == null
								|| closest.slot.x > window_rect.x) {
								closest = (DeepinWindowClone) window;
							}
						}
						break;
					case MotionDirection.UP:
						if (window_rect.y > current_rect.y) {
							continue;
						}

						// test for horizontal intersection
						if (window_rect.x + window_rect.width > current_rect.x
							&& window_rect.x < current_rect.x + current_rect.width) {

							if (closest == null
								|| closest.slot.y < window_rect.y) {
								closest = (DeepinWindowClone) window;
							}
						}
						break;
					case MotionDirection.DOWN:
						if (window_rect.y < current_rect.y) {
							continue;
						}

						// test for horizontal intersection
						if (window_rect.x + window_rect.width > current_rect.x
							&& window_rect.x < current_rect.x + current_rect.width) {

							if (closest == null
								|| closest.slot.y > window_rect.y) {
								closest = (DeepinWindowClone) window;
							}
						}
						break;
				}
			}

			if (closest == null) {
				return;
			}

			change_current_window (closest);
		}

		/**
		 * Emit the selected signal for the current_window.
		 */
		public void activate_selected_window ()
		{
			if (current_window != null) {
				current_window.activated ();
			}
		}

		/**
		 * When opened the WindowClones are animated to a clone layout
		 */
		public void open (Window? selected_window = null)
		{
			if (opened) {
				return;
			}

			opened = true;

			// reset the current window
			DeepinWindowClone? selected_window_clone = null;
			if (selected_window != null) {
				foreach (var child in get_children ()) {
					unowned DeepinWindowClone window_clone = (DeepinWindowClone) child;
					if (window_clone.window == selected_window) {
						selected_window_clone = window_clone;
						break;
					}
				}
			}
			change_current_window (selected_window_clone, false);

			foreach (var window in get_children ()) {
				((DeepinWindowClone) window).transition_to_original_state (false);
			}

			reflow ();
		}

		/**
		 * Calls the transition_to_original_state() function on each child
		 * to make them take their original locations again.
		 */
		public void close ()
		{
			if (!opened) {
				return;
			}

			opened = false;

			foreach (var window in get_children ()) {
				((DeepinWindowClone) window).transition_to_original_state (true);
			}
		}
	}
}
