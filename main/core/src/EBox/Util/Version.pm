# Copyright (C) 2010-2011 Zentyal S.L.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License, version 2, as
# published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

package EBox::Util::Version;

use strict;
use warnings;

# Function: compare
#
#        Compare two versions given its strings
#
# Parameters:
#
#        v1 - String first version
#
#        v2 - String second version
#
# Returns:
#
#        The same as built-in cmp does.
#
# Examples:
#
#        compare('1.2', '1.2')   => 0
#        compare('1.3', '1.3.1') => -1
#        compare('2.0', '1.9.9') => 1
#
sub compare
{
    my ($v1, $v2) = @_;

    my @v1 = split(/\./, $v1);
    my @v2 = split(/\./, $v2);

    my $min_len;
    if (scalar(@v1) < scalar(@v2)) {
        $min_len = scalar(@v1);
    } else {
        $min_len = scalar(@v2);
    }

    for (my $i = 0; $i < $min_len; $i++) {
        my $cmp = ($v1[$i] <=> $v2[$i]);
        $cmp and return $cmp;
    }
    return (scalar(@v1) <=> scalar(@v2));
}

1;
