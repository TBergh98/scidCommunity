/*
 * Copyright (C) 2026 scidCommunity contributors
 *
 * Scid is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation.
 *
 * Scid is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with Scid. If not, see <http://www.gnu.org/licenses/>.
 */

#include "scidbase.h"
#include "searchpos.h"
#include "treeindex.h"
#include <filesystem>
#include <fstream>
#include <gtest/gtest.h>

namespace {
const char* database = SCID_TESTDIR "res_database";

std::filesystem::path tempIndexPath() {
	return std::filesystem::temp_directory_path() / "scid_test_treeindex.tree";
}
} // namespace

// Every position stored in the index must have exactly the stats that the
// tree computes by searching the games, at every depth.
TEST(Test_TreeIndex, matches_tree_search) {
	scidBaseT dbase;
	ASSERT_EQ(OK, dbase.open("SCID4", FMODE_ReadOnly, database));
	const auto path = tempIndexPath();
	// Low thresholds, to index many positions of the small test database.
	ASSERT_EQ(OK, TreeIndex::build(dbase, path, {}, 2, 30, 4));

	TreeIndex index;
	ASSERT_EQ(TreeIndex::Status::Active, index.open(dbase, path));

	auto filter = dbase.getFilter(dbase.newFilter());
	size_t found[TreeIndex::kMaxDepth + 1] = {};
	for (gamenumT g = 0; g < dbase.numGames(); ++g) {
		Game game;
		ASSERT_EQ(OK, dbase.getGame(*dbase.getIndexEntry(g), game));
		game.MoveToStart();
		for (int ply = 0; ply < 30; ++ply) {
			const Position pos = *game.GetCurrentPos();
			bool filterSet = false;
			for (int depth = 1; depth <= TreeIndex::kMaxDepth; ++depth) {
				std::vector<TreeNode> fromIndex;
				if (!index.lookup(pos, fromIndex, depth))
					continue;
				++found[depth];
				if (!filterSet) {
					ASSERT_TRUE(SearchPos(pos).setFilter(dbase, filter, {}));
					filterSet = true;
				}
				const auto live = dbase.getTreeStat(filter, depth);
				ASSERT_EQ(live.size(), fromIndex.size())
				    << "game " << g + 1 << " ply " << ply << " depth " << depth;
				for (size_t i = 0; i < live.size(); ++i) {
					auto const& a = live[i];
					auto const& b = fromIndex[i];
					EXPECT_EQ(a.moves, b.moves);
					EXPECT_TRUE(std::equal(a.freq, a.freq + NUM_RESULT_TYPES,
					                       b.freq));
					EXPECT_EQ(a.eloCount, b.eloCount);
					EXPECT_EQ(a.eloWhiteSum, b.eloWhiteSum);
					EXPECT_EQ(a.eloBlackSum, b.eloBlackSum);
					EXPECT_EQ(a.yearCount, b.yearCount);
					EXPECT_EQ(a.yearSum, b.yearSum);
					EXPECT_EQ(a.lengthCount, b.lengthCount);
					EXPECT_EQ(a.lengthSum, b.lengthSum);
				}
			}
			if (game.MoveForward() != OK)
				break;
		}
	}
	EXPECT_GT(found[1], 1000u);
	for (int depth = 2; depth <= TreeIndex::kMaxDepth; ++depth)
		EXPECT_GT(found[depth], 100u) << "depth " << depth;
	index.open(dbase, {}); // unmap the file: Windows cannot remove it otherwise
	std::filesystem::remove(path);
}

TEST(Test_TreeIndex, status) {
	scidBaseT dbase;
	ASSERT_EQ(OK, dbase.open("SCID4", FMODE_ReadOnly, database));
	const auto path = tempIndexPath();
	std::filesystem::remove(path);

	TreeIndex index;
	EXPECT_EQ(TreeIndex::Status::Unsupported, index.open(dbase, {}));
	EXPECT_EQ(TreeIndex::Status::None, index.open(dbase, path));

	// Not an index file.
	{
		std::ofstream f(path, std::ios::binary);
		f << "not a tree index";
	}
	EXPECT_EQ(TreeIndex::Status::Stale, index.open(dbase, path));
	std::vector<TreeNode> out;
	EXPECT_FALSE(index.lookup(Position::getStdStart(), out));

	// An index built for another database.
	scidBaseT other;
	ASSERT_EQ(OK, other.open("MEMORY", FMODE_Create, "Memory"));
	ASSERT_EQ(OK, TreeIndex::build(other, path, {}));
	EXPECT_EQ(TreeIndex::Status::Stale, index.open(dbase, path));

	ASSERT_EQ(OK, TreeIndex::build(dbase, path, {}));
	EXPECT_EQ(TreeIndex::Status::Active, index.open(dbase, path));
	EXPECT_TRUE(index.lookup(Position::getStdStart(), out));
	EXPECT_FALSE(out.empty());
	index.open(dbase, {}); // unmap the file: Windows cannot remove it otherwise
	std::filesystem::remove(path);
}
