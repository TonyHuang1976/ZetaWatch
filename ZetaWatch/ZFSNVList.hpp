//
//  ZFSNVList.hpp
//  ZetaWatch
//
//  Created by Gerhard Röthlin on 2015.12.26.
//  Copyright © 2015 the-color-black.net. All rights reserved.
//
//  Redistribution and use in source and binary forms, with or without modification, are permitted
//  provided that the conditions of the "3-Clause BSD" license described in the BSD.LICENSE file are met.
//  Additional licensing options are described in the README file.
//

#ifndef ZETA_ZFSNVLIST_HPP
#define ZETA_ZFSNVLIST_HPP

#include <sys/nvpair.h>

#include <stdexcept>
#include <string>
#include <vector>

namespace zfs
{
	/*!
	 \brief A non-owning wrapper for using the zfs nvpair data structure more conveniently
	 */
	class NVPair
	{
	public:
		NVPair();
		NVPair(nvpair * pair);

	public:
		/*!
		 \returns true if this NVPair is valid, and has an associated nvpair, false otherwise.
		 */
		bool valid() const;

		/*!
		 \returns the name of this pair
		 */
		std::string name() const;

	public:
		/*
		 Converts the given nvpair to the given type if possible, writing the value into outValue.
		 Only the types `bool`, `char`, `std::string`, `NVList`, `int8_t`, `uint8_t`, `int16_t`,
		 `uint16_t`, `int32_t`, `uint32_t`, `int64_t`, `uint64_t` and vectors of them, as well
		 as double are supported.
		 \returns true if the NVPair can be converted, false otherwise
		 */
		template<typename T>
		bool convertTo(T & outValue) const;

		/*
		 Converts the given nvpair to the given type if possible
		 \returns the converted value
		 \throws std::logic_error otherwise
		 */
		template<typename T>
		T convertTo() const;

	public:
		data_type_t type() const;
		nvpair_t * toPair() const;

	public:
		std::string toString() const;
		bool streamName(std::ostream & os) const;
		bool streamValue(std::ostream & os) const;

	private:
		nvpair_t * m_pair;
	};

	std::ostream & operator<<(std::ostream & os, NVPair const & pair);

	/*!
	 \brief A wrapper for using the zfs nvlist data structure more conveniently
	 */
	class NVList
	{
	public:
		struct TakeOwnership {};

	public:
		NVList();
		NVList(nvlist * list);
		explicit NVList(nvlist * list, TakeOwnership);
		~NVList();

	public:
		NVList(NVList && other) noexcept;
		NVList & operator=(NVList && other) noexcept;

	public:
		/*
		 \returns true if this NVList is valid, and has an associated nvlist, false otherwise.
		 */
		bool valid() const;

		/*
		 \returns true if the associated nvlist is empty, false otherwise.
		 */
		bool empty() const;

		/*!
		 \returns true if an entry with the given key exists, false otherwise.
		 */
		bool exists(char const * key) const;

		/*!
		 Looks up the given key
		 \returns the associated value if it is found.
		 \throws std::out_of_range otherwise
		 */
		template<typename T>
		T lookup(char const * key) const;

		/*!
		 Looks up the given key. If it is found, the outValue parameter is set to that value.
		 \returns true if the given key is found, false otherwise
		 */
		template<typename T>
		bool lookup(char const * key, T & outValue) const;

	public:
		nvlist_t * toList() const;

	public:
		std::string toString() const;

	private:
		void reset();

	private:
		nvlist * m_list;
		bool m_ownsList;
	};

	std::ostream & operator<<(std::ostream & os, NVList const & list);

	// Private Implementation Follows

	template<typename T>
	T NVPair::convertTo() const
	{
		T value;
		if (!convertTo(value))
			throw std::logic_error("NVPair can not be converted to requested type");
		return value;
	}

	template<typename T>
	T NVList::lookup(char const * key) const
	{
		T value;
		if (!lookup(key, value))
			throw std::out_of_range(std::string("Key ") + key + " does not exist in NVList");
		return value;
	}

	template<typename T>
	bool NVList::lookup(char const * key, T & outValue) const
	{
		nvpair_t * pair = nullptr;
		if (nvlist_lookup_nvpair(m_list, key, &pair) != 0)
			return false;
		NVPair p(pair);
		return p.convertTo(outValue);
	}
}

#endif