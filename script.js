// Configuración de Firebase
const firebaseConfig = {
    apiKey: "AIzaSyAOy2gCytn6f13eTWAjPYQgqAw47UGqGu8",
    authDomain: "your-firebase-auth-domain",
    databaseURL: "https://your-database-url.firebaseio.com",
    projectId: "your-project-id",
    storageBucket: "your-storage-bucket.appspot.com",
    messagingSenderId: "your-sender-id",
    appId: "your-app-id"
};

const app = firebase.initializeApp(firebaseConfig);
const db = firebase.database();

// Variables globales
let map;
let userLocation;
const products = [];

// Inicializar el mapa y obtener la ubicación del usuario
function initMap() {
    map = new google.maps.Map(document.getElementById("map"), {
        zoom: 12,
        center: { lat: -34.397, lng: 150.644 },
    });

    if (navigator.geolocation) {
        navigator.geolocation.getCurrentPosition(
            position => {
                userLocation = {
                    lat: position.coords.latitude,
                    lng: position.coords.longitude,
                };

                map.setCenter(userLocation);

                new google.maps.Marker({
                    position: userLocation,
                    map: map,
                    title: "Tu ubicación",
                });
            },
            () => {
                alert("No se pudo obtener la ubicación.");
            }
        );
    } else {
        alert("La geolocalización no está soportada.");
    }
}

// Manejo del formulario de producto
document.getElementById("productForm").addEventListener("submit", function(event) {
    event.preventDefault();

    const productName = document.getElementById("productName").value;
    const productPrice = parseFloat(document.getElementById("productPrice").value);
    const storeName = document.getElementById("storeName").value;
    const productImage = document.getElementById("productImage").files[0];

    if (!productImage) {
        alert("Por favor, selecciona una imagen.");
        return;
    }

    const productLocation = userLocation;
    const productRef = db.ref("products").push();

    const productData = {
        name: productName,
        price: productPrice,
        store: storeName,
        image: URL.createObjectURL(productImage),
        location: productLocation,
        timestamp: Date.now(),
    };

    // Guardar en Firebase
    productRef.set(productData);

    alert("Producto ingresado correctamente.");
    displayBestPrice();
    addProductMarker(productData);
});

// Agregar un marcador en el mapa
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

// Mostrar el precio más bajo
function displayBestPrice() {
    const bestPriceBox = document.getElementById("bestPriceBox");

    db.ref("products").orderByChild("timestamp").on("value", snapshot => {
        let bestPrice = null;

        snapshot.forEach(productSnapshot => {
            const product = productSnapshot.val();

            // Filtrar productos dentro de los 20 km
            const distance = calculateDistance(userLocation, product.location);

            if (distance <= 20) {
                if (!bestPrice || product.price < bestPrice.price) {
                    bestPrice = product;
                }
            }
        });

        if (bestPrice) {
            bestPriceBox.innerHTML = `Mejor precio: <strong>${bestPrice.name}</strong> en <strong>${bestPrice.store}</strong> por $${bestPrice.price}`;
        } else {
            bestPriceBox.innerHTML = "No hay productos disponibles en tu área.";
        }
    });
}

// Función para calcular la distancia entre dos ubicaciones (en km)
function calculateDistance(loc1, loc2) {
    const R = 6371; // Radio de la Tierra en km
    const dLat = (loc2.lat - loc1.lat) * Math.PI / 180;
    const dLon = (loc2.lng - loc1.lng) * Math.PI / 180;

    const a =
        Math.sin(dLat / 2) * Math.sin(dLat / 2) +
        Math.cos(loc1.lat * Math.PI / 180) * Math.cos(loc2.lat * Math.PI / 180) *
        Math.sin(dLon / 2) * Math.sin(dLon / 2);
    const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
    return R * c; // Distancia en km
}
