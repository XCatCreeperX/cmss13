#define MAX_TRANSIT_REQUEST_RETRIES 10
#define SHUTTLE_SPAWN_BUFFER SSshuttle.wait * 10 /// Give a shuttle 10 "fires" (~10 seconds) to spawn before it can be cleaned up.

SUBSYSTEM_DEF(shuttle)
	name = "Shuttle"
	wait = 10
	init_order = SS_INIT_SHUTTLE
	flags = SS_KEEP_TIMING

	var/list/mobile = list()
	var/list/stationary = list()
	var/list/transit = list()

	/// For ID generation
	var/list/assoc_mobile = list()
	/// For ID generation
	var/list/assoc_stationary = list()

	var/list/transit_requesters = list()
	var/list/transit_request_failures = list()

	var/obj/docking_port/mobile/vehicle_elevator/vehicle_elevator

	var/list/hidden_shuttle_turfs = list() //all turfs hidden from navigation computers associated with a list containing the image hiding them and the type of the turf they are pretending to be
	var/list/hidden_shuttle_turf_images = list() //only the images from the above list

	var/lockdown = FALSE //disallow transit after nuke goes off

	var/datum/map_template/shuttle/selected

	var/obj/docking_port/mobile/existing_shuttle

	var/obj/docking_port/mobile/preview_shuttle
	var/datum/map_template/shuttle/preview_template

	var/datum/turf_reservation/preview_reservation

	/// safety to stop shuttles loading over each other
	var/loading_shuttle = FALSE

/datum/controller/subsystem/shuttle/Initialize(timeofday)
	if(GLOB.perf_flags & PERF_TOGGLE_SHUTTLES)
		can_fire = FALSE
		return
	initial_load()
	return SS_INIT_SUCCESS

/datum/controller/subsystem/shuttle/proc/initial_load()
	for(var/s in stationary)
		var/obj/docking_port/stationary/S = s
		S.load_roundstart()
		CHECK_TICK

/datum/controller/subsystem/shuttle/fire(resumed = FALSE)
	if(!resumed && (GLOB.perf_flags & PERF_TOGGLE_SHUTTLES))
		return
	for(var/thing in mobile)
		if(!thing)
			mobile.Remove(thing)
			continue
		var/obj/docking_port/mobile/P = thing
		P.check()
	for(var/thing in transit)
		var/obj/docking_port/stationary/transit/T = thing
		if(!T.owner)
			qdel(T, force=TRUE)
		// This next one removes transit docks/zones that aren't
		// immediately being used. This will mean that the zone creation
		// code will be running a lot.
		var/obj/docking_port/mobile/owner = T.owner
		if(owner && (world.time > T.spawn_time + SHUTTLE_SPAWN_BUFFER))
			var/idle = owner.mode == SHUTTLE_IDLE
			var/not_centcom_evac = owner.launch_status == NOLAUNCH
			var/not_in_use = (!T.get_docked())
			if(idle && not_centcom_evac && not_in_use)
				qdel(T, force=TRUE)

	if(!SSmapping.clearing_reserved_turfs)
		while(transit_requesters.len)
			var/requester = popleft(transit_requesters)
			var/success = generate_transit_dock(requester)
			if(!success) // BACK OF THE QUEUE
				transit_request_failures[requester]++
				if(transit_request_failures[requester] < MAX_TRANSIT_REQUEST_RETRIES)
					transit_requesters += requester
				else
					var/obj/docking_port/mobile/M = requester
					M.transit_failure()
					log_debug("[M.id] failed to get a transit zone")
			if(MC_TICK_CHECK)
				break

/datum/controller/subsystem/shuttle/proc/hasShuttle(id)
	for(var/obj/docking_port/mobile/M in mobile)
		if(M.id == id)
			return TRUE
	return FALSE

/datum/controller/subsystem/shuttle/proc/getShuttle(id)
	for(var/obj/docking_port/mobile/M in mobile)
		if(M.id == id)
			return M
	WARNING("couldn't find shuttle with id: [id]")

/datum/controller/subsystem/shuttle/proc/getDock(id)
	for(var/obj/docking_port/stationary/S in stationary)
		if(S.id == id)
			return S
	WARNING("couldn't find dock with id: [id]")

//try to move/request to dockHome if possible, otherwise dockAway. Mainly used for admin buttons
/datum/controller/subsystem/shuttle/proc/toggleShuttle(shuttleId, dockHome, dockAway, timed)
	var/obj/docking_port/mobile/M = getShuttle(shuttleId)
	if(!M)
		return DOCKING_BLOCKED
	var/obj/docking_port/stationary/dockedAt = M.get_docked()
	var/destination = dockHome
	if(dockedAt && dockedAt.id == dockHome)
		destination = dockAway
	if(timed)
		if(M.request(getDock(destination)))
			return DOCKING_IMMOBILIZED
	else
		if(M.initiate_docking(getDock(destination)) != DOCKING_SUCCESS)
			return DOCKING_IMMOBILIZED
	return DOCKING_SUCCESS	//dock successful

/**
 * Moves a shuttle to a new location
 *
 * Arguments:
 * * shuttle_id - The ID of the shuttle (mobile docking port) to move
 * * dock_id - The ID of the destination (stationary docking port) to move to
 * * timed - If true, have the shuttle follow normal spool-up, jump, dock process. If false, immediately move to the new location.
 */
/datum/controller/subsystem/shuttle/proc/moveShuttle(shuttleId, dockId, timed)
	var/obj/docking_port/stationary/D = getDock(dockId)
	var/obj/docking_port/mobile/M = getShuttle(shuttleId)

	return moveShuttleToDock(M, D, timed)

/datum/controller/subsystem/shuttle/proc/moveShuttleToDock(obj/docking_port/mobile/M, obj/docking_port/stationary/D, timed)
	if(!M)
		return DOCKING_NULL_SOURCE
	if(timed)
		if(M.request(D))
			return DOCKING_IMMOBILIZED
	else
		if(M.initiate_docking(D) != DOCKING_SUCCESS)
			return DOCKING_IMMOBILIZED
	return DOCKING_SUCCESS	//dock successful

/datum/controller/subsystem/shuttle/proc/request_transit_dock(obj/docking_port/mobile/M)
	if(!istype(M))
		throw EXCEPTION("[M] is not a mobile docking port")

	if(M.assigned_transit)
		return
	else
		if(!(M in transit_requesters))
			transit_requesters += M

/datum/controller/subsystem/shuttle/proc/generate_transit_dock(obj/docking_port/mobile/M)
	// First, determine the size of the needed zone
	// Because of shuttle rotation, the "width" of the shuttle is not
	// always x.
	var/dock_angle = dir2angle(M.preferred_direction) + dir2angle(M.port_direction) + 180
	var/dock_dir = angle2dir(dock_angle)

	var/transit_width = SHUTTLE_TRANSIT_BORDER * 2
	var/transit_height = SHUTTLE_TRANSIT_BORDER * 2

	// Shuttles travelling on their side have their dimensions swapped
	// from our perspective
	switch(dock_dir)
		if(NORTH, SOUTH)
			transit_width += M.width
			transit_height += M.height
		if(EAST, WEST)
			transit_width += M.height
			transit_height += M.width

/*
	to_chat(world, "The attempted transit dock will be [transit_width] width, and \)
		[transit_height] in height. The travel dir is [M.preferred_direction]."
*/

	var/transit_path = M.get_transit_path_type()

	var/datum/turf_reservation/proposal = SSmapping.RequestBlockReservation(transit_width, transit_height, null, /datum/turf_reservation/transit, transit_path)

	if(!istype(proposal))
		log_debug("generate_transit_dock() failed to get a block reservation from mapping system")
		return FALSE

	var/turf/bottomleft = locate(proposal.bottom_left_coords[1], proposal.bottom_left_coords[2], proposal.bottom_left_coords[3])
	// Then create a transit docking port in the middle
	var/coords = M.return_coords(0, 0, dock_dir)
	/* 0------2
		|   |
		|   |
		|  x   |
		3------1
	*/

	var/x0 = coords[1]
	var/y0 = coords[2]
	var/x1 = coords[3]
	var/y1 = coords[4]
	// Then we want the point closest to -infinity,-infinity
	var/xmin = min(x0, x1)
	var/ymin = min(y0, y1)

	// Then invert the numbers
	var/transit_x = bottomleft.x + SHUTTLE_TRANSIT_BORDER + abs(xmin)
	var/transit_y = bottomleft.y + SHUTTLE_TRANSIT_BORDER + abs(ymin)

	var/turf/midpoint = locate(transit_x, transit_y, bottomleft.z)
	if(!midpoint)
		log_debug("generate_transit_dock() failed to get a midpoint")
		return FALSE
	var/area/shuttle/transit/A = new()
	//A.parallax_movedir = travel_dir
	A.contents = proposal.reserved_turfs
	var/obj/docking_port/stationary/transit/new_transit_dock = new(midpoint)
	new_transit_dock.reserved_area = proposal
	new_transit_dock.name = "Transit for [M.id]/[M.name]"
	new_transit_dock.owner = M
	new_transit_dock.assigned_area = A

	// Add 180, because ports point inwards, rather than outwards
	new_transit_dock.setDir(angle2dir(dock_angle))

	M.assigned_transit = new_transit_dock
	return new_transit_dock

/datum/controller/subsystem/shuttle/Recover()
	if (istype(SSshuttle.mobile))
		mobile = SSshuttle.mobile
	if (istype(SSshuttle.stationary))
		stationary = SSshuttle.stationary
	if (istype(SSshuttle.transit))
		transit = SSshuttle.transit
	if (istype(SSshuttle.transit_requesters))
		transit_requesters = SSshuttle.transit_requesters
	if (istype(SSshuttle.transit_request_failures))
		transit_request_failures = SSshuttle.transit_request_failures

	lockdown = SSshuttle.lockdown

	selected = SSshuttle.selected

	existing_shuttle = SSshuttle.existing_shuttle

	preview_shuttle = SSshuttle.preview_shuttle
	preview_template = SSshuttle.preview_template

	preview_reservation = SSshuttle.preview_reservation


/datum/controller/subsystem/shuttle/proc/is_in_shuttle_bounds(atom/A)
	var/area/current = get_area(A)
	if(istype(current, /area/shuttle) && !istype(current, /area/shuttle/transit))
		return TRUE
	for(var/obj/docking_port/mobile/M in mobile)
		if(M.is_in_shuttle_bounds(A))
			return TRUE

/datum/controller/subsystem/shuttle/proc/get_containing_shuttle(atom/A)
	var/list/mobile_cache = mobile
	for(var/i in 1 to mobile_cache.len)
		var/obj/docking_port/port = mobile_cache[i]
		if(port.is_in_shuttle_bounds(A))
			return port

/datum/controller/subsystem/shuttle/proc/get_containing_dock(atom/A)
	. = list()
	var/list/stationary_cache = stationary
	for(var/i in 1 to stationary_cache.len)
		var/obj/docking_port/port = stationary_cache[i]
		if(port.is_in_shuttle_bounds(A))
			. += port

/datum/controller/subsystem/shuttle/proc/get_dock_overlap(x0, y0, x1, y1, z)
	. = list()
	var/list/stationary_cache = stationary
	for(var/i in 1 to stationary_cache.len)
		var/obj/docking_port/port = stationary_cache[i]
		if(!port || port.z != z)
			continue
		var/list/bounds = port.return_coords()
		var/list/overlap = get_overlap(x0, y0, x1, y1, bounds[1], bounds[2], bounds[3], bounds[4])
		var/list/xs = overlap[1]
		var/list/ys = overlap[2]
		if(xs.len && ys.len)
			.[port] = overlap

/datum/controller/subsystem/shuttle/proc/update_hidden_docking_ports(list/remove_turfs, list/add_turfs)
	var/list/remove_images = list()
	var/list/add_images = list()

	if(remove_turfs)
		for(var/T in remove_turfs)
			var/list/L = hidden_shuttle_turfs[T]
			if(L)
				remove_images += L[1]
		hidden_shuttle_turfs -= remove_turfs

	if(add_turfs)
		for(var/V in add_turfs)
			var/turf/T = V
			var/image/I
			if(remove_images.len)
				//we can just reuse any images we are about to delete instead of making new ones
				I = remove_images[1]
				remove_images.Cut(1, 2)
				I.loc = T
			else
				I = image(loc = T)
				add_images += I
			I.appearance = T.appearance
			I.override = TRUE
			hidden_shuttle_turfs[T] = list(I, T.type)

	hidden_shuttle_turf_images -= remove_images
	hidden_shuttle_turf_images += add_images

	QDEL_LIST(remove_images)


/datum/controller/subsystem/shuttle/proc/load_template_to_transit(datum/map_template/shuttle/template)
	UNTIL(!loading_shuttle)
	loading_shuttle = TRUE

	var/obj/docking_port/mobile/shuttle = action_load(template)

	if(!istype(shuttle))
		message_admins("Shuttle loading: [name] couldn't load a shuttle template")
		loading_shuttle = FALSE
		CRASH("Shuttle loading: ert shuttle failed to load")

	if(!shuttle.assigned_transit)
		generate_transit_dock(shuttle)

	if(!shuttle.assigned_transit)
		message_admins("Shuttle loading: shuttle failed to get an assigned transit dock.")
		shuttle.intoTheSunset()
		loading_shuttle = FALSE
		CRASH("Shuttle loading: ert shuttle failed to get an assigned transit dock")

	shuttle.initiate_docking(shuttle.assigned_transit)

	loading_shuttle = FALSE

	if(!shuttle.assigned_transit)
		message_admins("Shuttle loading: shuttle no longer has an assigned transit, trying to get it a new one")
		generate_transit_dock(shuttle)
		if(!shuttle.assigned_transit)
			message_admins("Shuttle loading: shuttle possibly failed because it no longer has an assigned transit, deleting it.")
			shuttle.intoTheSunset()
			CRASH("Shuttle loading: shuttle possibly failed because it no longer has an assigned transit, deleting it.")

	return shuttle

/datum/controller/subsystem/shuttle/proc/action_load(datum/map_template/shuttle/loading_template, obj/docking_port/stationary/destination_port)
	// Check for an existing preview
	if(preview_shuttle && (loading_template != preview_template))
		preview_shuttle.jumpToNullSpace()
		preview_shuttle = null
		preview_template = null
		QDEL_NULL(preview_reservation)

	if(!preview_shuttle)
		if(load_template(loading_template))
			preview_shuttle.linkup(loading_template, destination_port)
		preview_template = loading_template

	// get the existing shuttle information, if any
	var/timer = 0
	var/mode = SHUTTLE_IDLE
	var/obj/docking_port/stationary/D

	if(istype(destination_port))
		D = destination_port
	else if(existing_shuttle)
		timer = existing_shuttle.timer
		mode = existing_shuttle.mode
		D = existing_shuttle.get_docked()

	if(!D)
		D = generate_transit_dock(preview_shuttle)

	if(!D)
		preview_shuttle.jumpToNullSpace()
		CRASH("No dock found for preview shuttle ([preview_template.name]), aborting.")

	var/result = preview_shuttle.canDock(D)
	// truthy value means that it cannot dock for some reason
	// but we can ignore the someone else docked error because we'll
	// be moving into their place shortly
	if((result != SHUTTLE_CAN_DOCK) && (result != SHUTTLE_SOMEONE_ELSE_DOCKED))
		WARNING("Template shuttle [preview_shuttle] cannot dock at [D] ([result]).")
		return

	if(existing_shuttle)
		existing_shuttle.jumpToNullSpace()

	for(var/area/A as anything in preview_shuttle.shuttle_areas)
		for(var/turf/T as anything in A)
			// turfs inside the shuttle are not available for shuttles
			T.flags_atom &= ~UNUSED_RESERVATION_TURF

			// update underlays
			if(istype(T, /turf/closed/shuttle))
				var/dx = T.x - preview_shuttle.x
				var/dy = T.y - preview_shuttle.y
				var/turf/target_lz = locate(D.x + dx, D.y + dy, D.z)
				T.underlays.Cut()
				T.underlays += mutable_appearance(target_lz.icon, target_lz.icon_state, TURF_LAYER, FLOOR_PLANE)

	var/list/force_memory = preview_shuttle.movement_force
	preview_shuttle.movement_force = list("KNOCKDOWN" = 0, "THROW" = 0)
	preview_shuttle.initiate_docking(D)
	preview_shuttle.movement_force = force_memory

	. = preview_shuttle

	// Shuttle state involves a mode and a timer based on world.time, so
	// plugging the existing shuttles old values in works fine.
	preview_shuttle.timer = timer
	preview_shuttle.mode = mode

	preview_shuttle.register()

	// TODO indicate to the user that success happened, rather than just
	// blanking the modification tab
	preview_shuttle = null
	preview_template = null
	existing_shuttle = null
	selected = null
	QDEL_NULL(preview_reservation)

/datum/controller/subsystem/shuttle/proc/load_template(datum/map_template/shuttle/S)
	. = FALSE
	// load shuttle template, centred at shuttle import landmark,
	preview_reservation = SSmapping.RequestBlockReservation(S.width, S.height, SSmapping.transit.z_value, /datum/turf_reservation/transit)
	if(!preview_reservation)
		CRASH("failed to reserve an area for shuttle template loading")
	var/turf/BL = TURF_FROM_COORDS_LIST(preview_reservation.bottom_left_coords)
	S.load(BL, centered = FALSE, register = FALSE)

	var/affected = S.get_affected_turfs(BL, centered=FALSE)

	var/found = 0
	// Search the turfs for docking ports
	// - We need to find the mobile docking port because that is the heart of
	//   the shuttle.
	// - We need to check that no additional ports have slipped in from the
	//   template, because that causes unintended behaviour.
	for(var/T in affected)
		for(var/obj/docking_port/P in T)
			if(istype(P, /obj/docking_port/mobile))
				found++
				if(found > 1)
					qdel(P, force=TRUE)
					log_world("Map warning: Shuttle Template [S.mappath] has multiple mobile docking ports.")
				else
					preview_shuttle = P
			if(istype(P, /obj/docking_port/stationary))
				log_world("Map warning: Shuttle Template [S.mappath] has a stationary docking port.")
	if(!found)
		var/msg = "load_template(): Shuttle Template [S.mappath] has no mobile docking port. Aborting import."
		for(var/T in affected)
			var/turf/T0 = T
			T0.empty()

		message_admins(msg)
		WARNING(msg)
		return
	//Everything fine
	S.post_load(preview_shuttle)
	return TRUE

/datum/controller/subsystem/shuttle/proc/unload_preview()
	if(preview_shuttle)
		preview_shuttle.jumpToNullSpace()
	preview_shuttle = null

/datum/controller/subsystem/shuttle/ui_status(mob/user, datum/ui_state/state)
	return UI_INTERACTIVE

/datum/controller/subsystem/shuttle/tgui_interact(mob/user, datum/tgui/ui)
	ui = SStgui.try_update_ui(user, src, ui)
	if(!ui)
		ui = new(user, src, "ShuttleManipulator", name, 850, 600)
		ui.open()


/datum/controller/subsystem/shuttle/ui_data(mob/user)
	var/list/data = list()

	// Templates panel
	data["selected"] = list()

	data["template_data"] = list()
	for(var/shuttle_id in SSmapping.shuttle_templates)
		var/datum/map_template/shuttle/S = SSmapping.shuttle_templates[shuttle_id]
		var/list/template_data = list()
		template_data["name"] = S.name
		template_data["shuttle_id"] = S.shuttle_id
		template_data["description"] = S.description
		template_data["admin_notes"] = S.admin_notes

		if(selected == S)
			data["selected"] = template_data
		data["template_data"] += list(template_data)

	data["existing_shuttle"] = null
	// Status panel
	data["shuttles"] = list()
	for(var/i in mobile)
		var/obj/docking_port/mobile/M = i
		var/timeleft = M.timeLeft(1)
		var/list/L = list()
		L["name"] = M.name
		L["id"] = M.id
		L["timer"] = M.timer
		L["timeleft"] = M.getTimerStr()
		if (timeleft > 1 HOURS)
			L["timeleft"] = "Infinity"
		L["can_fast_travel"] = M.timer && timeleft >= 50
		L["can_fly"] = TRUE

		var/obj/structure/machinery/computer/shuttle/console = M.getControlConsole()
		L["has_disable"] = FALSE
		if(console)
			L["has_disable"] = TRUE
			L["is_disabled"] = console.is_disabled()

		if(!M.destination)
			L["can_fast_travel"] = FALSE
		if (M.mode != SHUTTLE_IDLE)
			L["mode"] = capitalize(M.mode)
		L["status"] = M.getDbgStatusText()
		if(M == existing_shuttle)
			data["existing_shuttle"] = L
		L["hijack"] = "N/A"

		data["shuttles"] += list(L)

	return data

/datum/controller/subsystem/shuttle/ui_act(action, params)
	if(..())
		return

	var/mob/user = usr

	// Preload some common parameters
	var/shuttle_id = params["shuttle_id"]
	var/datum/map_template/shuttle/S = SSmapping.shuttle_templates[shuttle_id]

	switch(action)
		if("select_template")
			if(S)
				if(hasShuttle(S.shuttle_id))
					existing_shuttle = getShuttle(S.shuttle_id)
				else
					existing_shuttle = null
				selected = S
				. = TRUE
		if("jump_to")
			if(params["type"] == "mobile")
				for(var/i in mobile)
					var/obj/docking_port/mobile/M = i
					if(M.id == params["id"])
						user.forceMove(get_turf(M))
						. = TRUE
						break
		if("lock")
			for(var/i in mobile)
				var/obj/docking_port/mobile/M = i
				if(M.id == params["id"])
					. = TRUE
					var/obj/structure/machinery/computer/shuttle/console = M.getControlConsole()
					console.disable()
					message_admins("[key_name_admin(user)] set [M.id]'s disabled to TRUE.")
					break
		if("unlock")
			for(var/i in mobile)
				var/obj/docking_port/mobile/M = i
				if(M.id == params["id"])
					. = TRUE
					var/obj/structure/machinery/computer/shuttle/console = M.getControlConsole()
					console.enable()
					message_admins("[key_name_admin(user)] set [M.id]'s disabled to FALSE.")
					break
		if("fly")
			for(var/i in mobile)
				var/obj/docking_port/mobile/M = i
				if(M.id == params["id"])
					. = TRUE
					M.admin_fly_shuttle(user)
					break

		if("fast_travel")
			for(var/i in mobile)
				var/obj/docking_port/mobile/M = i
				if(M.id == params["id"] && M.timer && M.timeLeft(1) >= 50)
					M.setTimer(50)
					. = TRUE
					message_admins("[key_name_admin(usr)] fast travelled [M]")
					log_admin("[key_name(usr)] fast travelled [M]")
					break

		if("preview")
			if(S)
				. = TRUE
				unload_preview()
				load_template(S)
				if(preview_shuttle)
					preview_template = S
					user.forceMove(get_turf(preview_shuttle))
		if("load")
			if(S)
				. = TRUE
				// If successful, returns the mobile docking port
				var/obj/docking_port/mobile/mdp = action_load(S)
				if(mdp)
					user.forceMove(get_turf(mdp))
					message_admins("[key_name_admin(usr)] loaded [mdp] with the shuttle manipulator.")
					log_admin("[key_name(usr)] loaded [mdp] with the shuttle manipulator.</span>")


#undef SHUTTLE_SPAWN_BUFFER
