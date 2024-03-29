--[[    作者:叶伟龙@龙川县赤光镇
        hub协程
--]]
_ENV=require('base').module(...)
require('class')

-- Copyright (c) 2009-2011 Denis Bilenko. See LICENSE for details.
--[[
Managing greenlets in a group.

The :class:`Group` class in this module abstracts a group of running
greenlets. When a greenlet dies, it's automatically removed from the
group. All running greenlets in a group can be waited on with
:meth:`Group.join`, or all running greenlets can be killed with
:meth:`Group.kill`.

The :class:`Pool` class, which is a subclass of :class:`Group`,
provides a way to limit concurrency: its :meth:`spawn <Pool.spawn>`
method blocks if the number of greenlets in the pool has already
reached the limit, until there is a free slot.
]]

-- from bisect import insort_right
-- try:
--	 from itertools import izip
-- except ImportError:
--	 # Python 3
--	 izip = zip

-- from gevent.hub import GreenletExit, getcurrent, kill as _kill
-- from gevent.greenlet import joinall, Greenlet
-- from gevent.timeout import Timeout
-- from gevent.event import Event
-- from gevent.lock import Semaphore, DummySemaphore

-- __all__ = ['Group', 'Pool']

require('routineSub')
--[===[
local IMapUnordered = class.create(routineSub.cRoutineSub)
local c = IMapUnordered
	--[[
	At iterator of map results.
	]]

	c._zipped = false

	function c.__init__(self, func, iterable, spawn, maxsize, _zipped)
        if _zipped == nil then _zipped = false
        -- spawn,maxsize可为nil

		--[[
		An iterator that.

		:keyword int maxsize: If given and not-nil, specifies the maximum number of
			finished results that will be allowed to accumulated awaiting the reader;
			more than that number of results will cause map function greenlets to begin
			to block. This is most useful is there is a great disparity in the speed of
			the mapping code and the consumer and the results consume a great deal of resources.
			Using a bound is more computationally expensive than not using a bound.

		.. versionchanged:: 1.1b3
			Added the *maxsize* parameter.
		]]
		-- from gevent.queue import Queue
		routineSub.cRoutineSub.__init__(self)
		if spawn ~= nil then
			self.spawn = spawn
		end
		if _zipped then
			self._zipped = _zipped
		end
		self.func = func
		self.iterable = iterable
		self.queue = queue.Queue()
		if maxsize then
			-- Bounding the queue is not enough if we want to keep from
			-- accumulating objects; the result value will be around as
			-- the greenlet's result, blocked on self.queue.put(), and
			-- we'll go on to spawn another greenlet, which in turn can
			-- create the result. So we need a semaphore to prevent a
			-- greenlet from exiting while the queue is full so that we
			-- don't spawn the next greenlet (assuming that self.spawn
			-- is of course bounded). (Alternatively we could have the
			-- greenlet itself do the insert into the pool, but that
			-- takes some rework).
			--
			-- Given the use of a semaphore at this level, sizing the queue becomes
			-- redundant, and that lets us avoid having to use self.link() instead
			-- of self.rawlink() to avoid having blocking methods called in the
			-- hub greenlet.
			factory = Semaphore
		else
			factory = DummySemaphore
		end
		self._result_semaphore = factory(maxsize)

		self.count = 0
		self.finished = false
		-- If the queue size is unbounded, then we want to call all
		-- the links (_on_finish and _on_result) directly in the hub greenlet
		-- for efficiency. However, if the queue is bounded, we can't do that if
		-- the queue might block (because if there's no waiter the hub can switch to,
		-- the queue simply raises Full). Therefore, in that case, we use
		-- the safer, somewhat-slower (because it spawns a greenlet) link() methods.
		-- This means that _on_finish and _on_result can be called and interleaved in any order
		-- if the call to self.queue.put() blocks..
		-- Note that right now we're not bounding the queue, instead using a semaphore.
		self.rawlink(self._on_finish)
	end

	function c.__iter__(self)
		return self
	end

	function c.next(self)
		self._result_semaphore.release()
		value = self._inext()
		if isinstance(value, Failure) then
			raise value.exc
		end
		return value
	end

	--__next__ = next

	function c._inext(self)
		return self.queue.get()
	end

	function c._ispawn(self, func, item)
		self._result_semaphore.acquire()
		self.count += 1
		g = self.spawn(func, item) if not self._zipped else self.spawn(func, *item)
		g.rawlink(self._on_result)
		return g
	end

	function c._run(self) -- pylint:disable=method-hidden
		try
			func = self.func
			for item in self.iterable do
				self._ispawn(func, item)
		finally
			self.__dict__.pop('spawn', nil)
			self.__dict__.pop('func', nil)
			self.__dict__.pop('iterable', nil)
	end

	function c._on_result(self, greenlet)
		-- This method can either be called in the hub greenlet (if the
		-- queue is unbounded) or its own greenlet. If it's called in
		-- its own greenlet, the calls to put() may block and switch
		-- greenlets, which in turn could mutate our state. So any
		-- state on this object that we need to look at, notably
		-- self.count, we need to capture or mutate *before* we put.
		-- (Note that right now we're not bounding the queue, but we may
		-- choose to do so in the future so this implementation will be left in case.)
		self.count -= 1
		count = self.count
		finished = self.finished
		ready = self.ready()
		put_finished = false

		if ready and count <= 0 and not finished then
			finished = self.finished = true
			put_finished = true
		end

		if greenlet.successful() then
			self.queue.put(self._iqueue_value_for_success(greenlet))
		else
			self.queue.put(self._iqueue_value_for_failure(greenlet))
		end

		if put_finished then
			self.queue.put(self._iqueue_value_for_finished())
		end
	end

	function c._on_finish(self, _self)
		if self.finished then
			return
		end

		if not self.successful() then
			self.finished = true
			self.queue.put(self._iqueue_value_for_self_failure())
			return
		end

		if self.count <= 0 then
			self.finished = true
			self.queue.put(self._iqueue_value_for_finished())
		end
	end

	function c._iqueue_value_for_success(self, greenlet)
		return greenlet.value
	end

	function c._iqueue_value_for_failure(self, greenlet)
		return Failure(greenlet.exception, getattr(greenlet, '_raise_exception'))
	end

	function c._iqueue_value_for_finished(self)
		return Failure(StopIteration)
	end

	function c._iqueue_value_for_self_failure(self)
		return Failure(self.exception, self._raise_exception)
	end
]===]

--[===[
local IMap = class.create(IMapUnordered)
	-- A specialization of IMapUnordered that returns items
	-- in the order in which they were generated, not
	-- the order in which they finish.
	-- We do this by storing tuples (order, value) in the queue
	-- not just value.

	function c.__init__(self, *args, **kwargs)
		self.waiting = {}  -- QQQ maybe deque will work faster there?
		self.index = 0
		self.maxindex = -1
		IMapUnordered.__init__(self, *args, **kwargs)
	end

	function c._inext(self)
		while true do
			if self.waiting and self.waiting[0][0] <= self.index then
				_, value = self.waiting.pop(0)
			else
				index, value = self.queue.get()
				if index > self.index then
					insort_right(self.waiting, (index, value))
					continue
				end
			end
			self.index = self.index + 1
			return value
		end
	end

	function c._ispawn(self, func, item)
		g = IMapUnordered._ispawn(self, func, item)
		self.maxindex += 1
		g.index = self.maxindex
		return g
	end

	function c._iqueue_value_for_success(self, greenlet)
		return (greenlet.index, IMapUnordered._iqueue_value_for_success(self, greenlet))
	end

	function c._iqueue_value_for_failure(self, greenlet)
		return (greenlet.index, IMapUnordered._iqueue_value_for_failure(self, greenlet))
	end

	function c._iqueue_value_for_finished(self)
		self.maxindex += 1
		return (self.maxindex, IMapUnordered._iqueue_value_for_finished(self))
	end

	function c._iqueue_value_for_self_failure(self)
		self.maxindex += 1
		return (self.maxindex, IMapUnordered._iqueue_value_for_self_failure(self))
	end
]===]

local GroupMappingMixin = class.create()
local c = GroupMappingMixin
	-- Internal, non-public API class.
	-- Provides mixin methods for implementing mapping pools. Subclasses must define:

	-- - self.spawn(func, *args, **kwargs): a function that runs `func` with `args`
	-- and `awargs`, potentially asynchronously. Return a value with a `get` method that
	-- blocks until the results of func are available, and a `link` method.

	-- - self._apply_immediately(): should the function passed to apply be called immediately,
	-- synchronously?

	-- - self._apply_async_use_greenlet(): Should apply_async directly call
	-- Greenlet.spawn(), bypassing self.spawn? Return true when self.spawn would block

	-- - self._apply_async_cb_spawn(callback, result): Run the given callback function, possiblly
	-- asynchronously, possibly synchronously.

	function c.apply_cb(self, func, args, kwds, callback)
        assert(func ~= nil)
        -- args,kwds,callback可为nil
		--[[
		:meth:`apply` the given *func(\\*args, \\*\\*kwds)*, and, if a *callback* is given, run it with the
		results of *func* (unless an exception was raised.)

		The *callback* may be called synchronously or asynchronously. If called
		asynchronously, it will not be tracked by this group. (:class:`Group` and :class:`Pool`
		call it asynchronously in a new greenlet; :class:`~gevent.threadpool.ThreadPool` calls
		it synchronously in the current greenlet.)
		]]
		local result = self:apply(func, args, kwds)
		if callback ~= nil then
			self:_apply_async_cb_spawn(callback, result)
		end
		return result
	end

	function c.apply_async(self, func, args, kwds, callback)
        assert(func ~= nil)
        -- args,kwds,callback可为nil
		--[[
		A variant of the :meth:`apply` method which returns a :class:`~.Greenlet` object.

		When the returned greenlet gets to run, it *will* call :meth:`apply`,
		passing in *func*, *args* and *kwds*.

		If *callback* is specified, then it should be a callable which
		accepts a single argument. When the result becomes ready
		callback is applied to it (unless the call failed).

		This method will never block, even if this group is full (that is,
		even if :meth:`spawn` would block, this method will not).

		.. caution:: The returned greenlet may or may not be tracked
		   as part of this group, so :meth:`joining <join>` this group is
		   not a reliable way to wait for the results to be available or
		   for the returned greenlet to run; instead, join the returned
		   greenlet.

		.. tip:: Because :class:`~.ThreadPool` objects do not track greenlets, the returned
		   greenlet will never be a part of it. To reduce overhead and improve performance,
		   :class:`Group` and :class:`Pool` may choose to track the returned
		   greenlet. These are implementation details that may change.
		]]
		if args == nil then
			args = {} --()
		end
		if kwds == nil then
			kwds = {}
		end
		if self:_apply_async_use_greenlet() then
			-- cannot call self.spawn() directly because it will block
			-- XXX: This is always the case for ThreadPool, but for Group/Pool
			-- of greenlets, this is only the case when they are full...hence
			-- the weasely language about "may or may not be tracked". Should we make
			-- Group/Pool always return true as well so it's never tracked by any
			-- implementation? That would simplify that logic, but could increase
			-- the total number of greenlets in the system and add a layer of
			-- overhead for the simple cases when the pool isn't full.
			return routineSub.cRoutineSub.spawn(self.apply_cb, func, args, kwds, callback)
		end

		local greenlet = self.spawn(func, *args, **kwds)
		if callback ~= nil then
			greenlet:link(pass_value(callback))
		end
		return greenlet
    end

	function c.apply(self, func, args, kwds)
        assert(func ~= nil)
        -- args,kwds可为nil
		--[[
		Rough quivalent of the :func:`apply()` builtin function blocking until
		the result is ready and returning it.

		The ``func`` will *usually*, but not *always*, be run in a way
		that allows the current greenlet to switch out (for example,
		in a new greenlet or thread, depending on implementation). But
		if the current greenlet or thread is already one that was
		spawned by this pool, the pool may choose to immediately run
		the `func` synchronously.

		Any exception ``func`` raises will be propagated to the caller of ``apply`` (that is,
		this method will raise the exception that ``func`` raised).
		]]
		if args == nil then
			args = {} --()
		end
		if kwds == nil then
			kwds = {}
		end
		if self:_apply_immediately() then
			return func(*args, **kwds)
		end
		return self.spawn(func, *args, **kwds).get()
	end

	function c.map(self, func, iterable)
		--[[Return a list made by applying the *func* to each element of
		the iterable.

		.. seealso:: :meth:`imap`
		]]
		return list(self.imap(func, iterable))
	end

	function c.map_cb(self, func, iterable, callback=nil)
		result = self.map(func, iterable)
		if callback is not nil then
			callback(result)
		end
		return result
	end

	function c.map_async(self, func, iterable, callback=nil)
		--[[
		A variant of the map() method which returns a Greenlet object that is executing
		the map function.

		If callback is specified then it should be a callable which accepts a
		single argument.
		]]
		return routineSub.cRoutineSub.spawn(self.map_cb, func, iterable, callback)
	end

	function c.__imap(self, cls, func, *iterables, **kwargs)
		-- Python 2 doesn't support the syntax that lets us mix varargs and
		-- a named kwarg, so we have to unpack manually
		local maxsize = kwargs.pop('maxsize', nil)
		if kwargs then
			error("Unsupported keyword arguments") --raise TypeError
		end
		return cls.spawn(func, izip(*iterables), spawn=self.spawn,
						 _zipped=true, maxsize=maxsize)
	end

	function c.imap(self, func, *iterables, **kwargs)
		--[[
		imap(func, *iterables, maxsize=nil) -> iterable

		An equivalent of :func:`itertools.imap`, operating in parallel.
		The *func* is applied to each element yielded from each
		iterable in *iterables* in turn, collecting the result.

		If this object has a bound on the number of active greenlets it can
		contain (such as :class:`Pool`), then at most that number of tasks will operate
		in parallel.

		:keyword int maxsize: If given and not-nil, specifies the maximum number of
			finished results that will be allowed to accumulate awaiting the reader;
			more than that number of results will cause map function greenlets to begin
			to block. This is most useful if there is a great disparity in the speed of
			the mapping code and the consumer and the results consume a great deal of resources.

			.. note:: This is separate from any bound on the number of active parallel
			   tasks, though they may have some interaction (for example, limiting the
			   number of parallel tasks to the smallest bound).

			.. note:: Using a bound is slightly more computationally expensive than not using a bound.

			.. tip:: The :meth:`imap_unordered` method makes much better
				use of this parameter. Some additional, unspecified,
				number of objects may be required to be kept in memory
				to maintain order by this function.

		:return: An iterable object.

		.. versionchanged:: 1.1b3
			Added the *maxsize* keyword parameter.
		.. versionchanged:: 1.1a1
			Accept multiple *iterables* to iterate in parallel.
		]]
		return self.__imap(IMap, func, *iterables, **kwargs)
	end

	function c.imap_unordered(self, func, *iterables, **kwargs)
		--[[
		imap_unordered(func, *iterables, maxsize=nil) -> iterable

		The same as :meth:`imap` except that the ordering of the results
		from the returned iterator should be considered in arbitrary
		order.

		This is lighter weight than :meth:`imap` and should be preferred if order
		doesn't matter.

		.. seealso:: :meth:`imap` for more details.
		]]
		return self.__imap(IMapUnordered, func, *iterables, **kwargs)
	end


Group = class.create(GroupMappingMixin)
local c = Group
	--[[
	Maintain a group of greenlets that are still running, without
	limiting their number.

	Links to each item and removes it upon notification.

	Groups can be iterated to discover what greenlets they are tracking,
	they can be tested to see if they contain a greenlet, and they know the
	number (len) of greenlets they are tracking. If they are not tracking any
	greenlets, they are false in a boolean context.
	]]

	--: The type of Greenlet object we will :meth:`spawn`. This can be changed
	--: on an instance or in a subclass.
	c.greenlet_class = routineSub.cRoutineSub

	function c.__init__(self, *args)
		assert len(args) <= 1, args
		self.greenlets = set(*args)
		if args then
			for greenlet in args[0] do
				greenlet.rawlink(self._discard)
			end
		end
		-- each item we kill we place in dying, to avoid killing the same greenlet twice
		self.dying = set()
		self._empty_event = Event()
		self._empty_event.set()
	end

	function c.__repr__(self)
		return '<%s at 0x%x %s>' % (self.__class__.__name__, id(self), self.greenlets)
	end

	function c.__len__(self)
		--[[
		Answer how many greenlets we are tracking. Note that if we are empty,
		we are false in a boolean context.
		]]
		return len(self.greenlets)
	end

	function c.__contains__(self, item)
		--[[
		Answer if we are tracking the given greenlet.
		]]
		return item in self.greenlets
	end

	function c.__iter__(self)
		--[[
		Iterate across all the greenlets we are tracking, in no particular order.
		]]
		return iter(self.greenlets)
	end

	function c.add(self, greenlet)
		--[[
		Begin tracking the greenlet.

		If this group is :meth:`full`, then this method may block
		until it is possible to track the greenlet.
		]]
		try
			rawlink = greenlet.rawlink
		except AttributeError
			pass  -- non-Greenlet greenlet, like MAIN
		else
			rawlink(self._discard)
		self.greenlets.add(greenlet)
		self._empty_event.clear()
	end

	function c._discard(self, greenlet)
		self.greenlets.discard(greenlet)
		self.dying.discard(greenlet)
		if not self.greenlets then
			self._empty_event:set()
		end
	end

	function c.discard(self, greenlet)
        assert(greenlet ~= nil)
		--[[
		Stop tracking the greenlet.
		]]
		self:_discard(greenlet)
		try
			unlink = greenlet.unlink
		except AttributeError
			pass  -- non-Greenlet greenlet, like MAIN
		else
			unlink(self._discard)
		end
	end

	function c.start(self, greenlet)
		--[[
		Start the un-started *greenlet* and add it to the collection of greenlets
		this group is monitoring.
		]]
		self:add(greenlet)
		greenlet:start()
	end

	function c.spawn(self, *args, **kwargs)
		--[[
		Begin a new greenlet with the given arguments (which are passed
		to the greenlet constructor) and add it to the collection of greenlets
		this group is monitoring.

		:return: The newly started greenlet.
		]]
		greenlet = self.greenlet_class(*args, **kwargs)
		self:start(greenlet)
		return greenlet
	end

--	 function c.close(self):
--		 --[[Prevents any more tasks from being submitted to the pool]]
--		 self.add = RaiseException("This %s has been closed" % self.__class__.__name__)

	function c.join(self, timeout, raise_error)
        if raise_error == nil then raise_error = false end
        -- timeout可为nil
		--[[
		Wait for this group to become empty *at least once*.

		If there are no greenlets in the group, returns immediately.

		.. note:: By the time the waiting code (the caller of this
		   method) regains control, a greenlet may have been added to
		   this group, and so this object may no longer be empty. (That
		   is, ``group.join(); assert len(group) == 0`` is not
		   guaranteed to hold.) This method only guarantees that the group
		   reached a ``len`` of 0 at some point.

		:keyword bool raise_error: If true (*not* the default), if any
			greenlet that finished while the join was in progress raised
			an exception, that exception will be raised to the caller of
			this method. If multiple greenlets raised exceptions, which
			one gets re-raised is not determined. Only greenlets currently
			in the group when this method is called are guaranteed to
			be checked for exceptions.

		:return bool: A value indicating whether this group became empty.
		   If the timeout is specified and the group did not become empty
		   during that timeout, then this will be a false value. Otherwise
		   it will be a true value.

		.. versionchanged:: 1.2a1
		   Add the return value.
		]]
		greenlets = list(self.greenlets) if raise_error else ()
		result = self._empty_event.wait(timeout=timeout)

		for greenlet in greenlets do
			if greenlet.exception is not nil then
				if hasattr(greenlet, '_raise_exception') then
					greenlet._raise_exception()
				end
				raise greenlet.exception
			end
		end
		return result
	end

	function c.kill(self, exception=GreenletExit, block=true, timeout=nil)
		
		--Kill all greenlets being tracked by this group.
		local timer = Timeout._start_new_or_dummy(timeout)
		try
			while self.greenlets do
				for greenlet in list(self.greenlets) do
					if greenlet in self.dying
						continue
					try
						kill = greenlet.kill
					except AttributeError
						_kill(greenlet, exception)
					else
						kill(exception, block=false)
					self.dying.add(greenlet)
				end
				if not block then
					break
				end
				joinall(self.greenlets)
			end
		except Timeout as ex
			if ex is not timer then
				raise
			end
		finally
			timer.cancel()

	function c.killone(self, greenlet, exception=GreenletExit, block=true, timeout=nil)
		--If the given *greenlet* is running and being tracked by this group,
		--kill it.
		
		if greenlet not in self.dying and greenlet in self.greenlets then
			greenlet.kill(exception, block=false)
			self.dying.add(greenlet)
			if block then
				greenlet.join(timeout)
			end
		end

	function c.full(self)
		--[[
		Return a value indicating whether this group can track more greenlets.

		In this implementation, because there are no limits on the number of
		tracked greenlets, this will always return a ``false`` value.
		]]
		return false
	end

	function c.wait_available(self, timeout=nil)
		--[[
		Block until it is possible to :meth:`spawn` a new greenlet.

		In this implementation, because there are no limits on the number
		of tracked greenlets, this will always return immediately.
		]]
	end

	-- MappingMixin methods

	function c._apply_immediately(self)
		-- If apply() is called from one of our own
		-- worker greenlets, don't spawn a new one---if we're full, that
		-- could deadlock.
		return getcurrent() in self
	end

	function c._apply_async_cb_spawn(self, callback, result)
		routineSub.cRoutineSub.spawn(callback, result)
	end

	function c._apply_async_use_greenlet(self)
		-- cannot call self.spawn() because it will block, so
		-- use a fresh, untracked greenlet that when run will
		-- (indirectly) call self.spawn() for us.
		return self:full()
	end

--[=[
Failure = class.create()
local c = Failure

	function c.__init__(self, exc, raise_exception=nil)
		self.exc = exc
		self._raise_exception = raise_exception
	end

	function c.raise_exc(self)
		if self._raise_exception then
			self._raise_exception()
		else
			raise self.exc
		end
	end
]=]

Pool = class.create(Group)
local c = Pool

	function c.__init__(self, size, greenlet_class)
        -- size, greenlet_class可为nil
		--[[
		Create a new pool.

		A pool is like a group, but the maximum number of members
		is governed by the *size* parameter.

		:keyword int size: If given, this non-negative integer is the
			maximum count of active greenlets that will be allowed in
			this pool. A few values have special significance:

			* ``nil`` (the default) places no limit on the number of
			  greenlets. This is useful when you need to track, but not limit,
			  greenlets, as with :class:`gevent.pywsgi.WSGIServer`. A :class:`Group`
			  may be a more efficient way to achieve the same effect.
			* ``0`` creates a pool that can never have any active greenlets. Attempting
			  to spawn in this pool will block forever. This is only useful
			  if an application uses :meth:`wait_available` with a timeout and checks
			  :meth:`free_count` before attempting to spawn.
		]]
		if size ~= nil and size < 0 then
			error(string.format('size must not be negative: %s', size)) --raise ValueError
        end
		Group.__init__(self)
		self.size = size
		if greenlet_class ~= nil then
			self.greenlet_class = greenlet_class
		end

        local factory
		if size == nil then
			factory = lock.DummySemaphore
		else
			factory = lock.Semaphore
		end
		self._semaphore = factory(size)
	end

	function c.wait_available(self, timeout)
        -- timeout可为nil
		--[[
		Wait until it's possible to spawn a greenlet in this pool.

		:param float timeout: If given, only wait the specified number
			of seconds.

		.. warning:: If the pool was initialized with a size of 0, this
		   method will block forever unless a timeout is given.

		:return: A number indicating how many new greenlets can be put into
		   the pool without blocking.

		.. versionchanged:: 1.1a3
			Added the ``timeout`` parameter.
		]]
		return self._semaphore:wait(timeout=timeout)
	end

	function c.full(self)
		--[[
		Return a boolean indicating whether this pool has any room for
		members. (true if it does, false if it doesn't.)
		]]
		return self:free_count() <= 0
	end

	function c.free_count(self)
		--[[
		Return a number indicating *approximately* how many more members
		can be added to this pool.
		]]
		if self.size == nil then
			return 1
		end
		return math.max(0, self.size - len(self))
	end

	function c.add(self, greenlet)
		--[[
		Begin tracking the given greenlet, blocking until space is available.

		.. seealso:: :meth:`Group.add`
		]]
		self._semaphore:acquire()
		try
			Group.add(self, greenlet)
		except
			self._semaphore:release()
			raise
	end

	function c._discard(self, greenlet)
		Group._discard(self, greenlet)
		self._semaphore:release()
	end

pass_value = class.create()
local c = pass_value
	
	function c.__init__(self, callback)
        assert(callback ~= nil)
		self.callback = callback
	end

	function c.__call(self, source)
        assert(source ~= nil)
		if source:successful() then
			self:callback(source.value)
		end
	end

	-- function c.__hash__(self)
	-- 	return hash(self.callback)
	-- end

	-- function c.__eq__(self, other)
	-- 	return self.callback == util.getAttr(other, 'callback', other)
	-- end

	-- function c.__str__(self)
	-- 	return str(self.callback)
	-- end

	-- function c.__repr__(self)
	-- 	return repr(self.callback)
	-- end

	-- function c.__getattr__(self, item)
	-- 	assert(item ~= nil)
	-- 	assert(item ~= 'callback')
	-- 	return util.getAttr(self.callback, item)
	-- end

require('queue')
require('lock')