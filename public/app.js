(function () {
  const mapEl = document.getElementById("map");
  if (!mapEl || typeof L === "undefined") return;

  const latInput = document.getElementById("latitude");
  const lngInput = document.getElementById("longitude");
  const accuracyInput = document.getElementById("accuracy");
  const readout = document.querySelector("[data-location-readout]");
  const locateButton = document.querySelector("[data-locate]");
  const readonly = mapEl.dataset.readonly === "true";

  const initialLat = parseFloat(mapEl.dataset.lat || "");
  const initialLng = parseFloat(mapEl.dataset.lng || "");
  const hasInitialPoint = Number.isFinite(initialLat) && Number.isFinite(initialLng);
  const defaultCenter = hasInitialPoint ? [initialLat, initialLng] : [52.0693, 19.4803];
  const defaultZoom = hasInitialPoint ? 17 : 6;

  const map = L.map(mapEl, {
    zoomControl: true,
    scrollWheelZoom: !readonly
  }).setView(defaultCenter, defaultZoom);

  L.tileLayer("https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png", {
    maxZoom: 19,
    attribution: "&copy; OpenStreetMap"
  }).addTo(map);

  let marker = null;
  let accuracyCircle = null;

  function formatNumber(value) {
    return Number(value).toFixed(6);
  }

  function setPoint(lat, lng, accuracy) {
    if (latInput) latInput.value = formatNumber(lat);
    if (lngInput) lngInput.value = formatNumber(lng);
    if (accuracyInput) accuracyInput.value = accuracy ? Math.round(accuracy) : "";

    if (!marker) {
      marker = L.marker([lat, lng], { draggable: !readonly }).addTo(map);
      if (!readonly) {
        marker.on("dragend", function () {
          const pos = marker.getLatLng();
          setPoint(pos.lat, pos.lng, null);
        });
      }
    } else {
      marker.setLatLng([lat, lng]);
    }

    if (accuracyCircle) {
      accuracyCircle.remove();
      accuracyCircle = null;
    }
    if (accuracy) {
      accuracyCircle = L.circle([lat, lng], {
        radius: accuracy,
        color: "#0f7fa8",
        fillColor: "#0f7fa8",
        fillOpacity: 0.12,
        weight: 1
      }).addTo(map);
    }

    if (readout) {
      const accuracyText = accuracy ? " · dokładność ok. " + Math.round(accuracy) + " m" : "";
      readout.textContent = formatNumber(lat) + ", " + formatNumber(lng) + accuracyText;
    }
  }

  if (hasInitialPoint) {
    setPoint(initialLat, initialLng, null);
  }

  if (!readonly) {
    map.on("click", function (event) {
      setPoint(event.latlng.lat, event.latlng.lng, null);
    });
  }

  if (locateButton && navigator.geolocation) {
    locateButton.addEventListener("click", function () {
      locateButton.disabled = true;
      locateButton.querySelector(".locate-label").textContent = "Szukam...";

      navigator.geolocation.getCurrentPosition(
        function (position) {
          const lat = position.coords.latitude;
          const lng = position.coords.longitude;
          const accuracy = position.coords.accuracy;
          setPoint(lat, lng, accuracy);
          map.setView([lat, lng], 18);
          locateButton.disabled = false;
          locateButton.querySelector(".locate-label").textContent = "Użyj GPS";
        },
        function () {
          if (readout) readout.textContent = "Nie udało się pobrać GPS. Dotknij mapy, aby zaznaczyć punkt.";
          locateButton.disabled = false;
          locateButton.querySelector(".locate-label").textContent = "Użyj GPS";
        },
        {
          enableHighAccuracy: true,
          timeout: 12000,
          maximumAge: 15000
        }
      );
    });
  }

  setTimeout(function () {
    map.invalidateSize();
  }, 250);
})();
