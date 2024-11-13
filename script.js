const products = [];
let map;
let userMarker;

// Inicializar el mapa y centrarse en la ubicación del usuario
function initMap() {
    map = new google.maps.Map(document.getElementById("map"), {
        zoom: 12,
        center: { lat: -34.397, lng: 150.644 },
    });

    // Obtener la ubicación del usuario
    if (navigator.geolocation) {
        navigator.geolocation.getCurrentPosition(
            position => {
                const pos = {
                    lat: position.coords.latitude,
                    lng: position.coords.longitude,
                };

                userMarker = new google.maps.Marker({
                    position: pos,
                    map: map,
                    title: "Mi ubicación",
                });

                map.setCenter(pos);
            },
            () => {
                alert("No se pudo obtener la ubicación.");
            }
        );
    } else {
        alert("La geolocalización no está soportada.");
    }
}

// Manejo del formulario para agregar productos
document.getElementById('productForm').addEventListener('submit', function(event) {
    event.preventDefault();

    const productName = document.getElementById('productName').value;
    const productPrice = parseFloat(document.getElementById('productPrice').value);
    const storeName = document.getElementById('storeName').value;
    const productImage = document.getElementById('productImage').files[0];

    if (!productImage) {
        alert("Por favor, selecciona una imagen del producto.");
        return;
    }

    if (userMarker && userMarker.getPosition()) {
        const productLocation = {
            lat: userMarker.getPosition().lat(),
            lng: userMarker.getPosition().lng()
        };

        const product = {
            name: productName,
            price: productPrice,
            store: storeName,
            image: URL.createObjectURL(productImage),
            location: productLocation
        };

        products.push(product);
        displayProducts();
        addProductMarker(product);
    } else {
        alert("Ubicación no disponible.");
    }
});

// Agregar marcador en el mapa
function addProductMarker(product) {
    const marker = new google.maps.Marker({
        position: product.location,
        map: map,
        title: `${product.name} - ${product.store}: $${product.price}`,
    });

    const infowindow = new google.maps.InfoWindow({
        content: `<strong>${product.name}</strong><br>${product.store}<br>$${product.price}`,
    });

    marker.addListener("click", () => {
        infowindow.open(map, marker);
    });
}

// Calcular distancia entre dos ubicaciones
function calculateDistance(loc1, loc2) {
    const R = 6371;
    const dLat = (loc2.lat - loc1.lat) * (Math.PI / 180);
    const dLon = (loc2.lng - loc1.lng) * (Math.PI / 180);
    const a = Math.sin(dLat / 2) * Math.sin(dLat / 2) +
              Math.cos(loc1.lat * (Math.PI / 180)) * Math.cos(loc2.lat * (Math.PI / 180)) *
              Math.sin(dLon / 2) * Math.sin(dLon / 2);
    return R * c;
}

// Mostrar productos y calcular el precio más bajo
function displayProducts() {
    const productList = document.getElementById('productList');
    productList.innerHTML = '';

    const nearbyProducts = products.filter(product => {
        return calculateDistance(product.location, userMarker.getPosition().toJSON()) <= 20;
    });

    let bestProduct = null;
    nearbyProducts.forEach(product => {
        const li = document.createElement('li');
        li.innerHTML = `<strong>${product.name}</strong> - ${product.store}: $${product.price}<br><img src="${product.image}" alt="${product.name}" style="width: 50px; height: auto;">`;

        if (!bestProduct || product.price < bestProduct.price) {
            bestProduct = product;
        }

        productList.appendChild(li);
    });

    const bestPriceBox = document.getElementById('bestPriceBox');
    if (bestProduct) {
        bestPriceBox.innerHTML = `Mejor precio: <strong>${bestProduct.name}</strong> en <strong>${bestProduct.store}</strong> por $${bestProduct.price}`;
    } else {
        bestPriceBox.innerHTML = "No hay productos en el rango de 20 km.";
    }
}
