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
  public enum StacksSortBy {
    MODIFIED,
    NAME,
    SIZE
  }

  public class StacksPreferences : DockItemPreferences {
    [Description (nick = "folder-path",
                  blurb = "Path to the folder to display")]
    public string FolderPath { get; set; default = ""; }

    [Description (nick = "sort-by",
                  blurb = "Sort order for files")]
    public StacksSortBy SortBy { get; set; default = StacksSortBy.MODIFIED; }

    [Description (nick = "show-hidden",
                  blurb = "Show hidden files")]
    public bool ShowHidden { get; set; default = false; }

    [Description (nick = "max-items",
                  blurb = "Maximum number of items to display")]
    public int MaxItems { get; set; default = 30; }

    public StacksPreferences.with_file (GLib.File file)
    {
      base.with_file (file);
    }

    protected override void reset_properties () {
      FolderPath = "";
      SortBy = StacksSortBy.MODIFIED;
      ShowHidden = false;
      MaxItems = 30;
    }
  }
}
