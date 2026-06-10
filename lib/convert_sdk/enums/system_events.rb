# frozen_string_literal: true

module ConvertSdk
  # SDK system event names, fired by EventManager across Epics 2-4. Wire strings
  # are byte-identical to the JS SDK
  # (javascript-sdk/packages/enums/src/system-events.ts).
  module SystemEvents
    # SDK is ready. Wire: +ready+.
    READY = "ready"
    # Remote config was updated. Wire: +config.updated+.
    CONFIG_UPDATED = "config.updated"
    # A bucketing decision was made. Wire: +bucketing+.
    BUCKETING = "bucketing"
    # A conversion was tracked. Wire: +conversion+.
    CONVERSION = "conversion"
    # The API request queue was released. Wire: +api.queue.released+.
    API_QUEUE_RELEASED = "api.queue.released"
    # Visitor segments were computed. Wire: +segments+.
    SEGMENTS = "segments"
    # A location was activated. Wire: +location.activated+.
    LOCATION_ACTIVATED = "location.activated"
    # A location was deactivated. Wire: +location.deactivated+.
    LOCATION_DEACTIVATED = "location.deactivated"
    # Audiences were evaluated. Wire: +audiences+.
    AUDIENCES = "audiences"
    # The datastore queue was released. Wire: +datastore.queue.released+.
    DATASTORE_QUEUE_RELEASED = "datastore.queue.released"
  end
end
