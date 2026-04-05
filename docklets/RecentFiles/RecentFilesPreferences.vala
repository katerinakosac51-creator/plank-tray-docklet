//
// Copyright (C) 2026 Plank Reloaded Developers
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

using Plank;

namespace Docky {
  public class RecentFilesPreferences : DockItemPreferences {
    [Description (nick = "max-items",
                  blurb = "Maximum number of recent files to display")]
    public int MaxItems { get; set; default = 20; }

    public RecentFilesPreferences.with_file (GLib.File file)
    {
      base.with_file (file);
    }

    protected override void reset_properties () {
      MaxItems = 20;
    }
  }
}
