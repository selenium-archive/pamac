/*
 *  pamac-vala
 *
 *  Copyright (C) 2014-2020 Guillaume Benoit <guillaume@manjaro.org>
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 3 of the License, or
 *  (at your option) any later version.
 *
 *  This program is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU General Public License for more details.
 *
 *  You should have received a get of the GNU General Public License
 *  along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

namespace Pamac {
	internal class AUR: Object {
		// AUR urls
		const string rpc_url = "https://aur.archlinux.org/rpc/?v=5";
		const string rpc_search = "&type=search&arg=";
		const string rpc_multiinfo = "&type=info";
		const string rpc_multiinfo_arg = "&arg[]=";
		Soup.Session session;
		HashTable<string, Json.Object> cached_infos;
		HashTable<string, Json.Array> search_results;

		public AUR () {
			Object ();
		}

		construct {
			session = new Soup.Session ();
			session.user_agent = "Pamac/%s".printf (VERSION);
			// set a 15 seconds timeout because it is also the dbus daemon timeout
			session.timeout = 15;
			cached_infos = new HashTable<string, Json.Object> (str_hash, str_equal);
			search_results = new HashTable<string, Json.Array> (str_hash, str_equal);
		}

		Json.Array get_json (string data, string uri) {
			var results = new Json.Array ();
			var parser = new Json.Parser ();
			try {
				parser.load_from_data (data, -1);
				unowned Json.Node? root = parser.get_root ();
				if (root != null) {
					if (root.get_object ().get_string_member ("type") == "error") {
						stderr.printf ("Failed to query %s from AUR\n", uri);
					} else {
						results = root.get_object ().get_array_member ("results");
					}
				}
			} catch (Error e) {
				warning (e.message);
				stderr.printf ("Failed to query %s from AUR\n", uri);
			}
			return results;
		}

		Json.Array rpc_query (string uri) {
			var message = new Soup.Message ("GET", uri);
			session.send_message (message);
			return get_json ((string) message.response_body.flatten ().data, uri);
		}

		Json.Array multiinfo (string[] pkgnames) {
			if (pkgnames.length == 0) {
				return new Json.Array ();
			}
			// query pkgnames hundred by hundred to avoid too long uri error
			// example: ros-lunar-desktop
			if (pkgnames.length <= 200) {
				var builder = new StringBuilder ();
				builder.append (rpc_url);
				builder.append (rpc_multiinfo);
				foreach (unowned string pkgname in pkgnames) {
					builder.append (rpc_multiinfo_arg);
					builder.append (Uri.escape_string (pkgname));
				}
				return rpc_query (builder.str);
			} else {
				var result = new Json.Array ();
				int index_max = pkgnames.length - 1;
				int index = 0;
				while (index < index_max) {
					var builder = new StringBuilder ();
					builder.append (rpc_url);
					builder.append (rpc_multiinfo);
					for (int i = 0; i < 200; i++) {
						unowned string pkgname = pkgnames[index];
						builder.append (rpc_multiinfo_arg);
						builder.append (Uri.escape_string (pkgname));
						index++;
						if (index == index_max) {
							break;
						}
					}
					var array = rpc_query (builder.str);
					array.foreach_element ((array, index, node) => {
						result.add_element (node);
					});
				}
				return result;
			}
		}

		void populate_infos (string[] pkgnames) {
			var names = new GenericArray<string> ();
			foreach (unowned string pkgname in pkgnames) {
				if (!(pkgname in cached_infos)) {
					names.add (pkgname);
				}
			}
			if (names.length > 0) {
				Json.Array results = multiinfo (names.data);
				results.foreach_element ((array, index, node) => {
					unowned Json.Object json_object = node.get_object ();
					cached_infos.insert (json_object.get_string_member ("Name"), json_object);
				});
			}
		}

		public unowned Json.Object? get_infos (string pkgname) {
			populate_infos ({pkgname});
			return cached_infos.lookup (pkgname);
		}

		public SList<unowned Json.Object> get_multi_infos (string[] pkgnames) {
			var result = new SList<unowned Json.Object> ();
			populate_infos (pkgnames);
			foreach (unowned string pkgname in pkgnames) {
				unowned Json.Object? object = cached_infos.lookup (pkgname);
				if (object != null) {
					result.prepend (object);
				}
			}
			result.reverse ();
			return result;
		}

		public SList<unowned Json.Object> search_aur (string search_string) {
			string[] needles = search_string.split (" ");
			if (needles.length == 0) {
				return new SList<unowned Json.Object> ();
			} else {
				var builder = new StringBuilder ();
				builder.append (rpc_url);
				builder.append (rpc_search);
				var all_found = new GenericArray<Json.Array> ();
				foreach (unowned string needle in needles) {
					if (needle in search_results) {
						all_found.add (search_results.lookup (needle));
					} else {
						var needle_builder = new StringBuilder (builder.str);
						needle_builder.append (Uri.escape_string (needle));
						Json.Array found = rpc_query (needle_builder.str);
						search_results.insert (needle, found);
						all_found.add (found);
					}
				}
				var result = new Json.Array ();
				for (uint i = 0; i < all_found.length; i++) {
					unowned Json.Array found = all_found[i];
					if (found.get_length () == 0) {
						continue;
					}
					if (result.get_length () == 0) {
						result = found;
						continue;
					}
					var inter = new Json.Array ();
					result.foreach_element ((result_array, result_index, result_node) => {
						found.foreach_element ((found_array, found_index, found_node) => {
							if (strcmp (result_node.get_object ().get_string_member ("Name"),
										found_node.get_object ().get_string_member ("Name")) == 0) {
								inter.add_element (result_node);
							}
						});
					});
					result = (owned) inter;
				}
				var pkgnames = new GenericArray<string> ();
				result.foreach_element ((array, index, node) => {
					pkgnames.add (node.get_object ().get_string_member ("Name"));
				});
				return get_multi_infos (pkgnames.data);
			}
		}
	}
}
