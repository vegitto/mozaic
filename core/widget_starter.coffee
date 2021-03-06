define ['cs!module', 'cs!pubsub'], (Module) ->
    class WidgetStarter extends Module
        ###
            Monitors the DOM for the appearance of new widgets.
            Loads them up whenever they appear.

            waiting_list: dictionary of channels, every value
                is a list of widgets neededing that channel to become available
            widgets: dictionary of widgets that still need some channels`
            channels: dictionary which retains available channels
        ###

        waiting_list: {}
        widgets: {}
        channels: {}
        widgets_for_gc: []

        checkIntervalForWidgetGarbageCollection: 10000
        garbageCollectionBatchSize: 30

        constructor: ->
            pipe = loader.get_module('pubsub')
            pipe.subscribe('/initialized_channel', (channel) =>
                # Make widget starter aware of incoming channels
                channel = channel.name
                @channels[channel] = true

                if not @waiting_list[channel] then @waiting_list[channel] = []
                # Consume widgets which are waiting on this channel
                while  (widget = @waiting_list[channel].shift())
                    @widgets[widget].unitialized_channels -= 1
                    if @widgets[widget].unitialized_channels == 0
                        @loadWidget(@widgets[widget].params)
                        delete @widgets[widget]
            )

        initialize: =>

            setInterval(@garbageCollectWidgets, @checkIntervalForWidgetGarbageCollection)
            document.addEventListener("DOMNodeInserted", (e) =>
                    $el = $(e.target)
                    # If the injected element is a widget, initialize it
                    list = []
                    if $el.hasClass('uberwidget')
                        list.push($el)
                    # Find all its children widgets and turn the pseudo-list
                    # returned by the jQuery API into a real list
                    inserted_elements = $el.find(".uberwidget")
                    for element in inserted_elements
                        list.push(element)

                    # Initialize all the widgets by calling setTimeout(0)
                    return @initializeNewWidgets(list)
            )
            document.addEventListener("DOMNodeRemoved", (e) =>
                    $el = $(e.target)
                    # If the removed element is a widget, garbage collect it.
                    # Be careful, some widgets are removed from the DOM
                    # before they have the chance to be initialized. Thus,
                    # they don't have a GUID yet, and nothing must be done.
                    if $el.hasClass('uberwidget')
                        @markForGarbageCollection($el)
                    # Find all its children widgets and initialize them
                    $el.find(".uberwidget").each( (idx, el) =>
                        @markForGarbageCollection(el)
                    )
                false
            )

        markForGarbageCollection: (el) =>
            ###
                Marks a DOM element containing a widget (can be either
                initialized or uninitialized) as ready for garbage collection.

                This has two consequences: first, the widget is puit into a
                garbage collection queue which will eventually garbage collect
                all their internal references and also unbind them from events.
                But this is an expensive operation and we need an easy way out
                until we stop receiving events (a detached widget will not
                receive any DOM events but only data events). Therefore,
                the second consequence is the setting of a flag for that widget
                which will immediately cause it to start ignoring data events.
            ###
            guid = $(el).attr('data-guid')
            return unless guid
            # First mark it as detached
            loader.mark_as_detached(guid)
            # And afterwards put it in the garbage collection queue.
            @widgets_for_gc.push(guid)

        initializeNewWidgets: (list) =>
            ###
                Recursive function for initializing the new widgets.

                The difference between this and a plain old for is that
                tries hard to let the rendering threads take what's theirs
                by calling setTimeout(0) for each step of the iteration.
            ###
            if (list.length == 0)
                return false
            widget = list.shift()
            @initializeWidget($(widget))
            setTimeout((=> @initializeNewWidgets(list)), 0)

        startWidget: (params) =>
            ###
                Checks if a widget can be started.
                The main reason for which widgets can't be started is that
                the datasource hasn't initialized all the data channels
                they are subscribed to.
            ###

            # No subscribed channels means no obligations :-)
            if not ('channels' of params)
                @loadWidget(params)
                return true

            unitialized_channels = _.keys(params.channels).length
            id = params.widget_id

            # See how many of widget channels are available and put
            # widget on a waiting list for uninitialized channels
            for k, v of params.channels
                if !@channels[v]?
                    if !@waiting_list[v]?
                        @waiting_list[v] = [id]
                    else
                        @waiting_list[v].push(id)
                else
                    unitialized_channels -= 1

            # If widget has all channels already initialize,
            if unitialized_channels == 0
                @loadWidget(params)
                return

            @widgets[id] =
                unitialized_channels: unitialized_channels
                params: params

        loadWidget: (params) =>
            loader.load_widget(params.name, params.widget_id, params)

        initializeWidget: ($el) =>
            # First thing, mark the widget as initialized
            $el.addClass('uberinitialized')

            # Generate a unique GUID as an id for the widget.
            widget_id = _.uniqueId('widget-')

            name = $el.data('widget')

            # Write the GUID to the DOM so that for debugging purposes
            $el.attr('data-guid', widget_id)

            # Extract widget initialization parameters from the DOM
            params = $.parseJSON($el.attr('data-params')) or {}
            params['el'] = $el
            params['name'] = name
            params['widget_id'] = widget_id

            # Start the widget
            @startWidget(params)

        garbageCollectWidgets: =>
            current_batch_size = Math.min(@garbageCollectionBatchSize, @widgets_for_gc.length)
            current_batch = @widgets_for_gc.splice(0, current_batch_size)
            for widget_id in current_batch
                loader.destroy_widget(widget_id)

    return WidgetStarter
