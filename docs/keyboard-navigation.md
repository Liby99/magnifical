Let's actually be more systematic about this. There are different kinds of navigation spaces which are available in different views:
  1) Yearly view
    a) Selected Month (Navigate Region)
    b) Selected All-Day Events (Navigate All-Day Events)
  2) Monthly view
    a) Selected Day (Navigate Region)
    b) Selected All-Day Events (Navigate All-Day Events)
  3) Weekly view
    a) Selected Hour (Navigate Region)
    b) Selected All-Day Events (Navigate All-Day Events)
    c) Selected Timed Events/Deadline (Navigate Timed Events)
  4) Daily view
    a) Selected Hour (Navigate Region)
    b) Selected All-Day Events (Navigate All-Day Events)
    c) Selected Timed Events/Deadline (Navigate Timed Events)
  In each view, we can use "Tab" to toggle the different keyboard navigation spaces. We select the closest element in the same view whenever possible:
    - for instance, in monthly view, selected day --> [tab] --> closest all-day-event to that day --> [tab] --> the day of the selected all-day-event
  We can use space bar to go from outer view to inner view when we are in "Navigate Region" mode
    - for instance, in yearly view, selected month --> [space] --> selected first day of the month in monthly view
    - for instance, in monthly view, selected day --> [space] --> selected hour closest to current time of the same day of the week in weekly view containing that selected day
    - in weekly view, selected day --> [space] --> daily view of that day
  We can use shift+= and shift+- to zoom-in
    - Whenever we zoom-in/out, we try our best to stay in the same navigate region.
    - For instance, if an all-day-event is selected, no matter how we zoom-in/out, our selection/focus should always be on that all-day-event
  The up/right/down/left arrows are for navigating within each navigation space, as suggested before.
    - In yearly view and navigate region, the up/down arrows are for selecting months
    - In yearly view and navigate all-day-events mode, the arrows are for selecting all-day events that can go across monthly boundaries
    - In other views, the navigation is more or less defined already
  This would unify the interaction scheme of the keys
