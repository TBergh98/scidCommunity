/*
 * Copyright (C) 2026  scidCommunity contributors.
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

/*
 * Fast tree: precomputed tree statistics stored in a file next to the
 * database (<database file>.tree).
 *
 * For every position reached by at least `threshold` games within the first
 * `maxPly` plies, the file holds one record per move played from it, with the
 * same statistics the tree window computes by reading the games. Records are
 * sorted by a 64-bit key of the position (board + side to move, the identity
 * the tree search uses), so a lookup is a binary search on a memory-mapped
 * file instead of a pass over millions of games.
 *
 * Positions that are not in the file (rarer or deeper ones) are computed by
 * the normal tree search, which is fast for them.
 *
 * The stats match the normal tree search, except for games that reach a
 * position only after maxPly plies, which are not counted (in a 13M-game base,
 * 3 of the 4.2M games after 1.d4, which shuffle back to it at ply 41-85).
 */

#pragma once

#include "common.h"
#include "filemap.h"
#include "tree.h"
#include <filesystem>
#include <vector>

class Position;
class Progress;
class scidBaseT;

class TreeIndex {
public:
	enum class Status {
		Unsupported, ///< The database has no files (clipbase, memory bases)
		None,        ///< No index file
		Stale,       ///< The file exists but does not match the database
		Active       ///< The file matches the database and is used
	};

	static constexpr unsigned kDefaultThreshold = 20;
	static constexpr unsigned kDefaultMaxPly = 30;

	/// @returns the path of the index file of @e base, or an empty path if
	///          the database has no files.
	static std::filesystem::path pathFor(const scidBaseT& base);

	/// Builds the index of @e base and writes it to @e path (through a
	/// temporary file, so an existing index is replaced only on success).
	/// @returns OK, ERROR_UserCancel if @e progress asked to stop, or the
	///          error that prevented writing the file.
	static errorT build(const scidBaseT& base, const std::filesystem::path& path,
	                    const Progress& progress,
	                    unsigned threshold = kDefaultThreshold,
	                    unsigned maxPly = kDefaultMaxPly);

	/// Opens the index file @e path and checks that it matches @e base.
	Status open(const scidBaseT& base, const std::filesystem::path& path);

	Status status() const { return status_; }

	/// Appends to @e out the moves played from @e pos, most played first.
	/// @returns false (and leaves @e out unchanged) if the index is not
	///          active or does not contain @e pos.
	bool lookup(const Position& pos, std::vector<TreeNode>& out) const;

	/// The key that identifies @e pos in the index.
	static uint64_t positionKey(const Position& pos);

private:
	FileMap<> file_;
	const char* records_ = nullptr;
	size_t nRecords_ = 0;
	Status status_ = Status::None;
};
