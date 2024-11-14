// Configuración de Firebase
const firebaseConfig = {
    apiKey: "AIzaSyDSPfuNhHxO3ILg_BO2uK6jmiTQvxxdrss",
    authDomain: "comparador-de-precios-ae4b4.firebaseapp.com",
    databaseURL: "https://comparador-de-precios-ae4b4-default-rtdb.firebaseio.com",
    projectId: "comparador-de-precios-ae4b4",
    storageBucket: "comparador-de-precios-ae4b4.firebasestorage.app",
    messagingSenderId: "764983752712",
    appId: "1:764983752712:web:9ceed2bc4cf7f76adaf9bd",
    measurementId: "G-WC3YSRPJ3P"
};

// Inicializar Firebase
firebase.initializeApp(firebaseConfig);
const database = firebase.database();

// Variables globales
let map;
let userLocation;

// Inicializar y mostrar el mapa
function initMap() {
    navigator.geolocation.getCurrentPosition(
        (position) => {
            userLocation = { lat: position.coords.latitude, lng: position.coords.longitude };
            map = new google.maps.Map(document.getElementById("map"), {
                center: userLocation,
                zoom: 13,
            });
            new google.maps.Marker({
                position: userLocation,
                map,
                title: "Tu ubicación",
            });
        },
        () => {
            alert("No se pudo obtener la ubicación");
        }
    );
}

// Guardar producto en Firebase
document.getElementById("addProductForm").addEventListener("submit", (e) => {
    e.preventDefault();
    const productName = document.getElementById("productName").value;
    const productPrice = parseFloat(document.getElementById("productPrice").value);
    const storeName = document.getElementById("storeName").value;

    const newProductRef = database.ref("products").push();
    newProductRef.set({
        productName,
        productPrice,
        storeName,
        latitude: userLocation.lat,
        longitude: userLocation.lng,
        timestamp: Date.now()
    });

    document.getElementById("addProductForm").reset();
    displayBestPrice(productName);
});

// Mostrar el mejor precio para el producto
function displayBestPrice(productName) {
    database.ref("products").orderByChild("productName").equalTo(productName).once("value", (snapshot) => {
        let bestProduct = null;

        snapshot.forEach((childSnapshot) => {
            const product = childSnapshot.val();
            if (!bestProduct || product.productPrice < bestProduct.productPrice) {
                bestProduct = product;
            }
        });

        if (bestProduct) {
            const bestPriceDetails = `
                <p><strong>Producto:</strong> ${bestProduct.productName}</p>
                <p><strong>Mejor precio:</strong> $${bestProduct.productPrice.toFixed(2)}</p>
                <p><strong>Tienda:</strong> ${bestProduct.storeName}</p>
            `;
            document.getElementById("bestPriceDetails").innerHTML = bestPriceDetails;

            const bestLocation = { lat: bestProduct.latitude, lng: bestProduct.longitude };
            new google.maps.Marker({
                position: bestLocation,
                map,
                title: `${bestProduct.productName} - ${bestProduct.storeName}`,
            });
            map.setCenter(bestLocation);
        } else {
            document.getElementById("bestPriceDetails").innerHTML = "<p>No se encontraron precios para este producto.</p>";
        }
    });
}

// Ejecutar la función initMap al cargar la página
window.onload = initMap;
